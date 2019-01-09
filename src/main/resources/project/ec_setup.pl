
# The plugin is being promoted, create a property reference in the server's property sheet
# Data that drives the create step picker registration for this plugin.
my %provision = (
                 label       => "vCloudDirector - Provision",
                 procedure   => "Provision",
                 description => "Instantiate a vApp template and deploy it",
                 category    => "Resource Management"
                );
my %capture = (
               label       => "vCloudDirector - Capture",
               procedure   => "Capture",
               description => "Creates a vApp template from an instantiated vApp",
               category    => "Resource Management"
              );
my %cleanup = (
               label       => "vCloudDirector - Cleanup",
               procedure   => "Cleanup",
               description => "Power off and optionally undeploy/delete a vApp",
               category    => "Resource Management"
              );
my %clone = (
             label       => "vCloudDirector - Clone",
             procedure   => "Clone",
             description => "Make a copy of a vApp to a specified virtual datacenter",
             category    => "Resource Management"
            );

my %getvApp = (
               label       => "vCloudDirector - GetvApp",
               procedure   => "GetvApp",
               description => "Get information of a vApp",
               category    => "Resource Management"
              );

my %startvApp = (
                 label       => "vCloudDirector - Start vApp",
                 procedure   => "Start vApp",
                 description => "Deploy/Power On a vApp.",
                 category    => "Resource Management"
                );

$batch->deleteProperty("/server/ec_customEditors/pickerStep/EC-vCloudDirector - Provision");
$batch->deleteProperty("/server/ec_customEditors/pickerStep/EC-vCloudDirector - Capture");
$batch->deleteProperty("/server/ec_customEditors/pickerStep/EC-vCloudDirector - Cleanup");
$batch->deleteProperty("/server/ec_customEditors/pickerStep/EC-vCloudDirector - Clone");
$batch->deleteProperty("/server/ec_customEditors/pickerStep/EC-vCloudDirector - CloudManagerShrink");
$batch->deleteProperty("/server/ec_customEditors/pickerStep/EC-vCloudDirector - CloudManagerGrow");

$batch->deleteProperty("/server/ec_customEditors/pickerStep/vCloudDirector - Provision");
$batch->deleteProperty("/server/ec_customEditors/pickerStep/vCloudDirector - Capture");
$batch->deleteProperty("/server/ec_customEditors/pickerStep/vCloudDirector - Cleanup");
$batch->deleteProperty("/server/ec_customEditors/pickerStep/vCloudDirector - Clone");
$batch->deleteProperty("/server/ec_customEditors/pickerStep/vCloudDirector - GetvApp");
$batch->deleteProperty("/server/ec_customEditors/pickerStep/vCloudDirector - Start vApp");

@::createStepPickerSteps = (\%provision, \%capture, \%cleanup, \%clone, \%getvApp, \%startvApp);
my $pluginName = "@PLUGIN_NAME@";
my $pluginKey  = "@PLUGIN_KEY@";
if ($promoteAction ne '') {
    my @objTypes = ('projects', 'resources', 'workspaces');
    my $query    = $commander->newBatch();
    my @reqs     = map { $query->getAclEntry('user', "project: $pluginName", { systemObjectName => $_ }) } @objTypes;
    push @reqs, $query->getProperty('/server/ec_hooks/promote');
    $query->submit();

    foreach my $type (@objTypes) {
        if ($query->findvalue(shift @reqs, 'code') ne 'NoSuchAclEntry') {
            $batch->deleteAclEntry('user', "project: $pluginName", { systemObjectName => $type });
        }
    }

    if ($promoteAction eq "promote") {
        foreach my $type (@objTypes) {
            $batch->createAclEntry(
                                   'user',
                                   "project: $pluginName",
                                   {
                                      systemObjectName           => $type,
                                      readPrivilege              => 'allow',
                                      modifyPrivilege            => 'allow',
                                      executePrivilege           => 'allow',
                                      changePermissionsPrivilege => 'allow'
                                   }
                                  );
        }
    }
}

if ($upgradeAction eq "upgrade") {
    my $query   = $commander->newBatch();
    my $newcfg  = $query->getProperty("/plugins/$pluginName/project/vclouddirector_cfgs");
    my $oldcfgs = $query->getProperty("/plugins/$otherPluginName/project/vclouddirector_cfgs");
    my $creds   = $query->getCredentials("\$[/plugins/$otherPluginName]");

    local $self->{abortOnError} = 0;
    $query->submit();

    # if new plugin does not already have cfgs
    if ($query->findvalue($newcfg, "code") eq "NoSuchProperty") {

        # if old cfg has some cfgs to copy
        if ($query->findvalue($oldcfgs, "code") ne "NoSuchProperty") {
            $batch->clone(
                          {
                            path      => "/plugins/$otherPluginName/project/vclouddirector_cfgs",
                            cloneName => "/plugins/$pluginName/project/vclouddirector_cfgs"
                          }
                         );
        }
    }

    # Copy configuration credentials and attach them to the appropriate steps
    my $nodes = $query->find($creds);
    if ($nodes) {
        my @nodes = $nodes->findnodes('credential/credentialName');
        for (@nodes) {
            my $cred = $_->string_value;

            # Clone the credential
            $batch->clone(
                          {
                            path      => "/plugins/$otherPluginName/project/credentials/$cred",
                            cloneName => "/plugins/$pluginName/project/credentials/$cred"
                          }
                         );

            # Make sure the credential has an ACL entry for the new project principal
            my $xpath = $commander->getAclEntry(
                                                "user",
                                                "project: $pluginName",
                                                {
                                                   projectName    => $otherPluginName,
                                                   credentialName => $cred
                                                }
                                               );
            if ($xpath->findvalue("//code") eq "NoSuchAclEntry") {
                $batch->deleteAclEntry(
                                       "user",
                                       "project: $otherPluginName",
                                       {
                                          projectName    => $pluginName,
                                          credentialName => $cred
                                       }
                                      );
                $batch->createAclEntry(
                                       "user",
                                       "project: $pluginName",
                                       {
                                          projectName                => $pluginName,
                                          credentialName             => $cred,
                                          readPrivilege              => 'allow',
                                          modifyPrivilege            => 'allow',
                                          executePrivilege           => 'allow',
                                          changePermissionsPrivilege => 'allow'
                                       }
                                      );
            }

            # Attach the credential to the appropriate steps
            $batch->attachCredential(
                                     "\$[/plugins/$pluginName/project]",
                                     $cred,
                                     {
                                        procedureName => 'Provision',
                                        stepName      => 'Provision'
                                     }
                                    );
            $batch->attachCredential(
                                     "\$[/plugins/$pluginName/project]",
                                     $cred,
                                     {
                                        procedureName => 'Clone',
                                        stepName      => 'Clone'
                                     }
                                    );
            $batch->attachCredential(
                                     "\$[/plugins/$pluginName/project]",
                                     $cred,
                                     {
                                        procedureName => 'Capture',
                                        stepName      => 'Capture'
                                     }
                                    );
            $batch->attachCredential(
                                     "\$[/plugins/$pluginName/project]",
                                     $cred,
                                     {
                                        procedureName => 'Cleanup',
                                        stepName      => 'Cleanup'
                                     }
                                    );

            $batch->attachCredential(
                                     "\$[/plugins/$pluginName/project]",
                                     $cred,
                                     {
                                        procedureName => 'GetvApp',
                                        stepName      => 'GetvApp'
                                     }
                                    );
            $batch->attachCredential(
                                     "\$[/plugins/$pluginName/project]",
                                     $cred,
                                     {
                                        procedureName => 'Start vApp',
                                        stepName      => 'Start vApp'
                                     }
                                    );
        }
    }
}
