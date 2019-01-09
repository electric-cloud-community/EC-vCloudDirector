=head1 NAME

vCloudDirector

=head1 DESCRIPTION

API integreation for VMWare VCloudDirector

=head1 AUTHOR

Electric Cloud, Inc.

=head1 LICENSE

Copyright Electric Cloud, Inc. 2014

=cut

package vCloudDirector;

# -------------------------------------------------------------------------
# Includes
# -------------------------------------------------------------------------
use strict;
use warnings;
use ElectricCommander::PropDB;
use Carp;
use LWP::UserAgent;
use MIME::Base64;
use Encode;
use utf8;

use open IO => ':encoding(utf8)';

use XML::XPath;
use XML::Simple;
use Data::Dumper;

# -------------------------------------------------------------------------
# Constants
# -------------------------------------------------------------------------
use constant {
    SUCCESS => 0,
    ERROR   => 1,

    DEFAULT_DEBUG        => 1,
    DEFAULT_API_VERSION  => '1.0',
    DEFAULT_API_LOGIN  => '/api/v1.0/login',
    DEFAULT_LOCATION     => "/myJob/vCloudDirector/deployed",
    DEFAULT_PING_TIMEOUT => 100,

    ALIVE     => 1,
    NOT_ALIVE => 0,

    WAIT_SLEEP_TIME => 15,

    TASK_SUCCESS => 1,
    TASK_ERROR   => 2,
    TASK_QUEUED  => 3,

    EMPTY => q{},
    # RETRY_ON_FAILURE_INTERVAL => 5,

};

# -------------------------------------------------------------------------
# Globals
# -------------------------------------------------------------------------
$::authHeader = undef;    # used to hold auth header with credentials
$::browser    = undef;    # used to hold the main browser object

# -------------------------------------------------------------------------
# Main functions
# -------------------------------------------------------------------------

###########################################################################

=head2 new
 
  Title    : new
  Usage    : new($ec, $opts);
  Function : Object constructor for vCloudDirector.
  Returns  : vCloudDirector instance
  Args     : named arguments:
           : -_cmdr => ElectricCommander instance
           : -_opts => hash of parameters from procedures
           :
=cut

###########################################################################
sub new {
    my ($class, $cmdr, $opts, $retry_on_failure) = @_;
    my $self = {
        _cmdr => $cmdr,
        _opts => $opts,
        retry_on_failure => $retry_on_failure
    };
    bless $self, $class;
    return $self;
}

###########################################################################

=head2 provision
 
  Title    : provision
  Usage    : $self->provision();
  Function : Instantiate and deploy a vApp
  Returns  : none
  Args     : none
           :
=cut

###########################################################################
sub provision {
    my $self = shift;

    $self->debug_msg(1, '-' x 69);
    $self->initialize();

    $self->initialize_prop_prefix;
    if ($self->ecode) { return; }

    my $urlPrefix = $self->opts->{api_url};
    my $api_xmlns;
    my $message;
    my $result;
    my $xml;

    if ($self->opts->{vcloud_fenced_mode} eq 'natRouted' && !$self->opts->{vcloud_parent_network}) {
        croak "When natRouted fence mode chosen, parent network should be specified";
    }
    #-----------------------------
    # Create new LWP browser
    #-----------------------------
    $::browser = LWP::UserAgent->new(agent => 'perl LWP', cookie_jar => {});

    #-----------------------------
    # LOGIN
    #-----------------------------
    $self->login();
    if ($self->ecode) { return; }
    $api_xmlns = $self->opts->{api_xmlns};

    #-----------------------------
    # GET ORGANIZATION
    #-----------------------------
    my $organizationHref = $self->get_organization($urlPrefix);
    if ($self->ecode) { return; }

    #-----------------------------
    # GET CATALOG
    #-----------------------------
    my $catalogHref = $self->get_catalog($organizationHref);
    if ($self->ecode) { return; }
    $self->opts->{vcloud_catalog_href} = $catalogHref;
    #-----------------------------
    # GET VDC
    #-----------------------------
    my $vdcHref = $self->get_vdc($organizationHref);
    if ($self->ecode) { return; }

    #-----------------------------
    # FIND VAPP TEMPLATE
    #-----------------------------
    my $templateHref = $self->get_template($vdcHref);
    if ($self->ecode) { return; }

    #-----------------------------
    # GET VDC INFO
    #-----------------------------
    $xml = $self->get_vdc_info($vdcHref);
    if ($self->ecode) { return; }

    my $xPath = XML::XPath->new($xml);

    #-----------------------------
    # GET ADD HREF
    #-----------------------------
    $self->debug_msg(5, 'Getting add href...');
    my $nodeset = $xPath->find('/Vdc/Link');
    my $addHref;
    my $addType;
    foreach my $node ($nodeset->get_nodelist) {
        if (   ($node->findvalue('@rel')->string_value eq 'add')
            && ($node->findvalue('@type')->string_value eq 'application/vnd.vmware.vcloud.instantiateVAppTemplateParams+xml'))
        {
            $addHref = $node->findvalue('@href')->string_value;
            $addType = $node->findvalue('@type')->string_value;
            last;
        }
    }
    $self->debug_msg(5, '    Add href: ' . $addHref);
    $self->debug_msg(5, 'Getting add type...');
    $self->debug_msg(5, '    Add type: ' . $addType);

    #-----------------------------
    # Get parentNetwork href
    #-----------------------------
    my $parentNetworkHref = EMPTY;
    if (defined($self->opts->{vcloud_parent_network}) && $self->opts->{vcloud_parent_network} ne EMPTY) {
        $self->debug_msg(5, 'Getting parent network href...');
        $nodeset = $xPath->find('/Vdc/AvailableNetworks/Network');

        foreach my $node ($nodeset->get_nodelist) {
            if (   ($node->findvalue('@name')->string_value eq $self->opts->{vcloud_parent_network})
                && ($node->findvalue('@type')->string_value eq 'application/vnd.vmware.vcloud.network+xml'))
            {
                $parentNetworkHref = $node->findvalue('@href')->string_value;
                last;
            }
        }

        if ($parentNetworkHref eq EMPTY) {
            $self->debug_msg(0, "Network '" . $self->opts->{vcloud_parent_network} . "' not found in VDC " . $self->opts->{vcloud_virtual_datacenter});
            $self->opts->{exitcode} = ERROR;
            return;
        }
        $self->debug_msg(5, '    Network href: ' . $parentNetworkHref);
    }

    #-----------------------------
    # INSTANTIATE TEMPLATE IN THE VDC
    #-----------------------------
    $self->debug_msg(1, 'Instantiating the template \'' . $self->opts->{vcloud_template} . '\' to create vApp \'' . $self->opts->{vcloud_vappname} . '\'...');

    $message = "<InstantiateVAppTemplateParams name=\"" . $self->opts->{vcloud_vappname} . "\" xmlns=\"$api_xmlns\" xmlns:ovf=\"http://schemas.dmtf.org/ovf/envelope/1\">
        <InstantiationParams>";

    if (defined($self->opts->{vcloud_network}) && $self->opts->{vcloud_network} ne EMPTY && $parentNetworkHref ne EMPTY) {
        if ($self->opts->{vcloud_fenced_mode} eq 'natRouted') {
            $message .= '';
        }
        else {
            $message .= "<NetworkConfigSection>
                <ovf:Info>Configuration parameters for vAppNetwork</ovf:Info>
                <NetworkConfig networkName=\"" . $self->opts->{vcloud_network} . "\">
                    <Configuration>
                        <ParentNetwork href=\"$parentNetworkHref\"/>
                        <FenceMode>" . $self->opts->{vcloud_fenced_mode} . "</FenceMode>
                        <Features>
                             <FirewallService>
                               <IsEnabled>true</IsEnabled>
                               <DefaultAction>allow</DefaultAction>
                               <LogDefaultAction>false</LogDefaultAction>
                             </FirewallService>
                             <NatService>
                               <IsEnabled>true</IsEnabled>
                               <NatType>ipTranslation</NatType>
                               <Policy>allowTraffic</Policy>
                             </NatService>
                          </Features>

                    </Configuration>
                </NetworkConfig>
            </NetworkConfigSection>";
        }

    }

    $message .= "</InstantiationParams>
        <Source href=\"$templateHref\"/>
        <AllEULAsAccepted>true</AllEULAsAccepted>
    </InstantiateVAppTemplateParams>";

    $xml = $self->issue_request("POST", $addHref, $addType, $message);
    if ($self->ecode) { return; }
    $xPath = XML::XPath->new($xml);

    #-----------------------------
    # Get new vApp href
    #-----------------------------
    $nodeset = $xPath->find('/VApp');
    my $node     = $nodeset->get_node(1);
    my $vAppHref = $node->findvalue('@href')->string_value;

    $self->{vapp_href} = $vAppHref;
    $self->debug_msg(6, "Get status");

    #-----------------------------
    # Wait for the vApp to be ready
    #-----------------------------
    my $taskStatus;
    my $vAppXMLData;

    do {
        #-----------------------------
        # Keep getting the info until status different to 0
        #-----------------------------
        print "...";
        sleep(WAIT_SLEEP_TIME);

        $xml = $self->issue_request("GET", $vAppHref, EMPTY, EMPTY);
        $vAppXMLData = $xml;

        if ($self->ecode) { return; }
        $xPath = XML::XPath->new($xml);

        $nodeset    = $xPath->find('/VApp');
        $node       = $nodeset->get_node(1);
        $taskStatus = $node->findvalue('@status')->string_value;
        
        #-----------------------------
        # If error
        #-----------------------------
        if ($taskStatus eq "-1") {
            die "Task status -1: The object could not be created.";
        }
        print "\n";

    } while ($taskStatus ne "8");

    if ($self->opts->{vcloud_fenced_mode} eq 'natRouted') {
        # ncs = Network Config Section
        my $ncs_href = '';
        my $vapp_nodeset = $xPath->find('//NetworkConnectionSection');
        for my $node ($nodeset->get_nodelist()) {
            $ncs_href = $node->findvalue('@href')->string_value();
        }
        $ncs_href = $vAppHref . '/networkConfigSection';
        my $ncs_xml = $self->issue_request(GET => $ncs_href, undef, undef);
        my $t = qq|<ParentNetwork href="$parentNetworkHref"/>\n<FenceMode>natRouted</FenceMode>\n|;
        if ($ncs_xml !~ m/<Features>/s) {
            $t.= qq|<Features>
                <FirewallService>
                    <IsEnabled>true</IsEnabled>
                    <DefaultAction>allow</DefaultAction>
                    <LogDefaultAction>false</LogDefaultAction>
                </FirewallService>
                <NatService>
                    <IsEnabled>true</IsEnabled>
                    <NatType>ipTranslation</NatType>
                    <Policy>allowTraffic</Policy>
                </NatService>
            </Features>|;
        }
        $ncs_xml =~ s|(?:<ParentNetwork.+?>)?\s*?<FenceMode>.+?<\/FenceMode>|$t|gms;
        $ncs_xml =~ s|<RetainNetInfoAcrossDeployments>.+?<\/RetainNetInfoAcrossDeployments>||gms;
        my $res_t = $self->issue_request(
            PUT => $ncs_href,
            'application/vnd.vmware.vcloud.networkConfigSection+xml',
            $ncs_xml
        );
        $self->wait_for_all_tasks_of_vapp($vAppHref);
    }
    $self->debug_msg(0, 'Template \'' . $self->opts->{vcloud_template} . '\' succesfully instantiated');

    my ($vAppName, $vAppHostname) = (
        $self->opts->{vcloud_vappname},
        $self->opts->{vcloud_vapp_hostname}
    );



    #-----------------------------
    # Get deploy href for the vApp
    #-----------------------------
    my $deployHref;
    $self->debug_msg(5, 'Getting Deploy vApp href...');
    $nodeset = $xPath->find('/VApp/Link');

    foreach my $node ($nodeset->get_nodelist) {
        if ($node->findvalue('@rel')->string_value eq 'deploy') {
            $deployHref = $node->findvalue('@href')->string_value;
            last;
        }
    }
    $self->debug_msg(5, '    Deploy vApp href: ' . $deployHref);

    #-----------------------------
    # Update guestcustomizationsection
    #-----------------------------
    if ($self->opts->{vcloud_vapp_hostname}) {
        my @vmidReference = $self->getVmidReference($vAppXMLData);
        my $iterator = 0;
        if (scalar @vmidReference > 1) {
            for my $vmidref (@vmidReference) {
                $iterator++;
                my $temp_hostname = $self->opts->{vcloud_vapp_hostname};
                $temp_hostname .= '-' . $iterator;

                $self->updateVm(
                    $vmidref,
                    vapp_name      => $self->opts->{vcloud_vappname},
                    vapp_hostname  => $temp_hostname,
                    vm_name        => $temp_hostname,
                );
            }
        }
        elsif (scalar @vmidReference == 1) {
            $self->updateVm(
                $vmidReference[0],
                vapp_name     =>  $self->opts->{vcloud_vappname},
                vapp_hostname =>  $self->opts->{vcloud_vapp_hostname},
                vm_name     =>  $self->opts->{vcloud_vapp_hostname}
            );
        }
        else {
            $self->error("VMID reference wasn't found");
        }
	}
    
    #-----------------------------
    # DEPLOY AND POWER ON THE VAPP
    #-----------------------------
    $self->debug_msg(1, 'Deploying vApp \'' . $self->opts->{vcloud_vappname} . '\'...');

    $message = "<DeployVAppParams powerOn=\"true\" deploymentLeaseSeconds=\"2592000\" xmlns=\"$api_xmlns\"/>";
    $self->wait_for_all_tasks_of_vapp($vAppHref);
    $xml = $self->issue_request("POST", $deployHref, 'application/vnd.vmware.vcloud.deployVAppParams+xml', $message);
    if ($self->ecode) { return; }
    $xPath = XML::XPath->new($xml);

    #-----------------------------
    # WAIT UNTIL TASK COMPLETES, IS QUEDED, OR RETURNS ERROR
    #-----------------------------

    $nodeset = $xPath->find('/Task');
    $node    = $nodeset->get_node(1);
    my $taskHref = $node->findvalue('@href')->string_value;

    $result = $self->wait_task($taskHref);

    $self->wait_for_all_tasks_of_vapp($vAppHref);

    if ($self->opts->{vcloud_dns_wait_time}) {
    	$self->debug_msg(6, "Waiting for DNS: " . $self->opts->{vcloud_dns_wait_time} . ' seconds');
    	sleep $self->opts->{vcloud_dns_wait_time};
    }

    if ($self->ecode) { return; }

    if ($result == TASK_SUCCESS) {
        $self->debug_msg(0, 'vApp \'' . $self->opts->{vcloud_vappname} . '\' succesfully deployed');
    }
    elsif ($result == TASK_ERROR) {
        $self->debug_msg(0, 'Error: Failed to deploy vApp \'' . $self->opts->{vcloud_vappname} . '\'');
        $self->opts->{exitcode} = ERROR;

        $self->debug_msg(1, 'Deleting vApp \'' . $self->opts->{vcloud_vappname} . '\'...');

        $xml = $self->issue_request("DELETE", $vAppHref, EMPTY, EMPTY);
        if ($self->ecode) { return; }
        $xPath = XML::XPath->new($xml);

        #-----------------------------
        # WAIT UNTIL TASK COMPLETES, IS QUEDED, OR RETURNS ERROR
        #-----------------------------
        $nodeset = $xPath->find('/Task');
        $node    = $nodeset->get_node(1);
        my $taskHref = $node->findvalue('@href')->string_value;

        $result = $self->wait_task($taskHref);
        if ($self->ecode) { return; }

        if ($result == TASK_SUCCESS) {
            $self->debug_msg(0, 'vApp \'' . $self->opts->{vcloud_vappname} . '\' succesfully deleted');
        }
        elsif ($result == TASK_ERROR) {
            $self->debug_msg(0, 'Error: Failed to delete vApp \'' . $self->opts->{vcloud_vappname} . '\'');
            $self->opts->{exitcode} = ERROR;
        }
        elsif ($result == TASK_QUEUED) {
            $self->debug_msg(0, 'The task for deleting vApp \'' . $self->opts->{vcloud_vappname} . '\' has been queued for execution');
        }
        return;
    }
    elsif ($result == TASK_QUEUED) {
        $self->debug_msg(0, 'The task for the deployment of vApp \'' . $self->opts->{vcloud_vappname} . '\' has been queued for execution');
    }

    if ($self->opts->{vcloud_poweroff_vapp}) {
        $self->debug_msg(0, "Peroforming PowerOff");
        my $poweroff_href = $vAppHref . '/action/undeploy';

        $self->debug_msg(0, "Poweroff href: " . $poweroff_href);

        my $x2 = qq|<?xml version="1.0" encoding="UTF-8" standalone="no"?>
            <UndeployVAppParams xmlns="http://www.vmware.com/vcloud/v1.5">
            <UndeployPowerAction>powerOff</UndeployPowerAction>
            </UndeployVAppParams>
        |;
        $xml = $self->issue_request(
            POST => $poweroff_href,
            "application/vnd.vmware.vcloud.undeployVAppParams+xml",
            $x2
        );
    }
    #-----------------------------
    #STORE RESULTS ON PROPERTIES
    #-----------------------------
    $self->store_properties($vAppHref);
    if ($self->ecode) { return; }
    return;

}

###########################################################################

=head2 cleanup
 
  Title    : cleanup
  Usage    : $self->cleanup();
  Function : Power off and undeploy/delete vApp
  Returns  : none
  Args     : none
           :
=cut

###########################################################################
sub cleanup {
    my $self = shift;
    $self->debug_msg(1, '---------------------------------------------------------------------');
    $self->initialize();
    $self->initialize_prop_prefix;
    if ($self->ecode) { return; }

    my $url;
    my $message;
    my $xml;
    my $urlPrefix = $self->opts->{api_url};

    my $api_xmlns;
    my $result;
    my $req;

    #-----------------------------
    # Create new LWP browser
    #-----------------------------
    $::browser = LWP::UserAgent->new(agent => 'perl LWP', cookie_jar => {});

    #-----------------------------
    # LOGIN
    #-----------------------------
    $self->login();
    if ($self->ecode) { return; }
    $api_xmlns = $self->opts->{api_xmlns};
    
    #-----------------------------
    # GET ORGANIZATION
    #-----------------------------
    my $organizationHref = $self->get_organization($urlPrefix);
    if ($self->ecode) { return; }

    #-----------------------------
    # GET VDC
    #-----------------------------
    my $vdcHref = $self->get_vdc($organizationHref);
    if ($self->ecode) { return; }

    #-----------------------------
    # GET VDC INFO
    #-----------------------------
    $xml = $self->get_vdc_info($vdcHref);
    if ($self->ecode) { return; }

    my $xPath = XML::XPath->new($xml);

    #-----------------------------
    # GET VAPP INFO
    #-----------------------------
    $self->debug_msg(5, 'Getting vApp href...');
    my $nodeset  = $xPath->find('/Vdc/ResourceEntities/ResourceEntity');
    my $vAppHref = EMPTY;
    foreach my $node ($nodeset->get_nodelist) {
        if ($node->findvalue('@name')->string_value eq $self->opts->{vcloud_vappname}) {
            $vAppHref = $node->findvalue('@href')->string_value;
            last;
        }
    }

    if ($vAppHref eq EMPTY) {
        $self->debug_msg(0, '    vApp: ' . $self->opts->{vcloud_vappname} . ' not found. Already deleted.');

        #-------------------------------------
        # Delete resources (if created)
        #-------------------------------------
        my @resources = $self->get_deployed_resource_list();

        $self->debug_msg(1, "Cleaning up resources");
        foreach my $machineName (@resources) {
            $self->debug_msg(1, "Deleting resource " . $machineName);
            my $cmdrresult = $self->my_cmdr()->deleteResource($machineName);

            #-----------------------------
            # Check for error return
            #-----------------------------
            my $errMsg = $self->my_cmdr()->checkAllErrors($cmdrresult);
            if ($errMsg ne EMPTY) {
                $self->debug_msg(1, "Error: $errMsg");
                $self->opts->{exitcode} = ERROR;
                next;
            }
            $self->debug_msg(1, "Resource '" . $machineName . "' deleted.");

        }
        return;
    }

    $self->debug_msg(5, '    vApp href: ' . $vAppHref);

    $xml = $self->issue_request("GET", $vAppHref, EMPTY, EMPTY);
    if ($self->ecode) { return; }
    $xPath = XML::XPath->new($xml);

    $nodeset = $xPath->find('/VApp');
    my $node   = $nodeset->get_node(1);
    my $status = $node->findvalue('@status')->string_value;

    my $powerOffHref = EMPTY;
    my $undeployHref = EMPTY;

    $self->debug_msg(5, 'Getting vApp Power Off href...');
    $nodeset = $xPath->find('/VApp/Link');
    foreach my $node ($nodeset->get_nodelist) {
        if ($node->findvalue('@rel')->string_value eq 'power:powerOff') {
            $powerOffHref = $node->findvalue('@href')->string_value;
        }
        if ($node->findvalue('@rel')->string_value eq 'undeploy') {
            $undeployHref = $node->findvalue('@href')->string_value;
        }
    }
    $self->debug_msg(5, '    vApp Power Off href:[' . $powerOffHref . ']');
    $self->debug_msg(5, '    status: ' . $status);

    if ($status eq "4" && $powerOffHref ne EMPTY) {

        #-----------------------------
        # POWER OFF VAPP
        #-----------------------------
        $self->debug_msg(1, 'Powering off vApp \'' . $self->opts->{vcloud_vappname} . '\'...');

        $xml = $self->issue_request("POST", $powerOffHref, EMPTY, EMPTY);
        if ($self->ecode) { return; }
        $xPath = XML::XPath->new($xml);

        #-----------------------------
        # WAIT UNTIL TASK COMPLETES, IS QUEDED, OR RETURNS ERROR
        #-----------------------------
        $nodeset = $xPath->find('/Task');
        my $node     = $nodeset->get_node(1);
        my $taskHref = $node->findvalue('@href')->string_value;

        $result = $self->wait_task($taskHref);
        if ($self->ecode) { return; }

        if ($result == TASK_SUCCESS) {
            $self->debug_msg(0, 'vApp \'' . $self->opts->{vcloud_vappname} . '\' succesfully powered off');
        }
        elsif ($result == TASK_ERROR) {
            $self->debug_msg(0, 'Error: Failed to power off vApp \'' . $self->opts->{vcloud_vappname} . '\'');
            $self->opts->{exitcode} = ERROR;
            return;
        }
        elsif ($result == TASK_QUEUED) {
            $self->debug_msg(0, 'The task for powering off vApp \'' . $self->opts->{vcloud_vappname} . '\' has been queued for execution');
        }
    }

    #-----------------------------
    # UNDEPLOY VAPP
    #-----------------------------
    if ($undeployHref ne EMPTY && defined($self->opts->{vcloud_undeploy}) && $self->opts->{vcloud_undeploy}) {
        $self->debug_msg(1, 'Undeploying vApp \'' . $self->opts->{vcloud_vappname} . '\'...');
        $self->debug_msg(5, 'Getting vApp Undeploy href...');
        $self->debug_msg(5, '    vApp Undeploy href: ' . $undeployHref);
$message = "<UndeployVAppParams xmlns=\"$api_xmlns\"/>";
        
        $xml = $self->issue_request("POST", $undeployHref, 'application/vnd.vmware.vcloud.undeployVAppParams+xml', $message);
        if ($self->ecode) { return; }
        $xPath = XML::XPath->new($xml);

        #-----------------------------
        # WAIT UNTIL TASK COMPLETES, IS QUEDED, OR RETURNS ERROR
        #-----------------------------
        $nodeset = $xPath->find('/Task');
        $node    = $nodeset->get_node(1);
        my $taskHref = $node->findvalue('@href')->string_value;

        $result = $self->wait_task($taskHref);
        if ($self->ecode) { return; }

        if ($result == TASK_SUCCESS) {
            $self->debug_msg(0, 'vApp \'' . $self->opts->{vcloud_vappname} . '\' succesfully undeployed');
        }
        elsif ($result == TASK_ERROR) {
            $self->debug_msg(0, 'Error: Failed to undeploy vApp \'' . $self->opts->{vcloud_vappname} . '\'');
            $self->opts->{exitcode} = ERROR;
        }
        elsif ($result == TASK_QUEUED) {
            $self->debug_msg(0, 'The task for undeploying vApp \'' . $self->opts->{vcloud_vappname} . '\' has been queued for execution');
        }
    }

    #-------------------------------------
    # Delete resources (if created)
    #-------------------------------------
    my @resources = $self->get_deployed_resource_list();

    $self->debug_msg(1, "Cleaning up resources");
    foreach my $machineName (@resources) {
        $self->debug_msg(1, "Deleting resource " . $machineName);
        my $cmdrresult = $self->my_cmdr()->deleteResource($machineName);

        #-----------------------------
        # Check for error return
        #-----------------------------
        my $errMsg = $self->my_cmdr()->checkAllErrors($cmdrresult);
        if ($errMsg ne EMPTY) {
            $self->debug_msg(1, "Error: $errMsg");
            $self->opts->{exitcode} = ERROR;
            next;
        }
        $self->debug_msg(1, "Resource '" . $machineName . "' deleted.");

    }

    #-----------------------------
    # DELETE VAPP
    #-----------------------------
    if (defined($self->opts->{vcloud_delete}) && $self->opts->{vcloud_delete}) {
        $self->debug_msg(1, 'Deleting vApp \'' . $self->opts->{vcloud_vappname} . '\'...');

        $self->wait_for_all_tasks_of_vapp($vAppHref);
        $xml = $self->issue_request("DELETE", $vAppHref, EMPTY, EMPTY);
        if ($self->ecode) { return; }
        $xPath = XML::XPath->new($xml);

        #-----------------------------
        # WAIT UNTIL TASK COMPLETES, IS QUEDED, OR RETURNS ERROR
        #-----------------------------
        $nodeset = $xPath->find('/Task');
        $node    = $nodeset->get_node(1);
        my $taskHref = $node->findvalue('@href')->string_value;

        $result = $self->wait_task($taskHref);
        if ($self->ecode) { return; }

        if ($result == TASK_SUCCESS) {
            $self->debug_msg(0, 'vApp \'' . $self->opts->{vcloud_vappname} . '\' succesfully deleted');
        }
        elsif ($result == TASK_ERROR) {
            $self->debug_msg(0, 'Error: Failed to delete vApp \'' . $self->opts->{vcloud_vappname} . '\'');
            $self->opts->{exitcode} = ERROR;
        }
        elsif ($result == TASK_QUEUED) {
            $self->debug_msg(0, 'The task for deleting vApp \'' . $self->opts->{vcloud_vappname} . '\' has been queued for execution');
        }
    }
    return;
}

###########################################################################

=head2 clone
 
  Title    : clone
  Usage    : $self->clone();
  Function : Create a copy of a vApp.
  Returns  : none
  Args     : none
           :
=cut

###########################################################################
sub clone {
    my $self = shift;

    $self->debug_msg(1, '---------------------------------------------------------------------');
    $self->initialize();
    $self->initialize_prop_prefix;

    my $url;
    my $urlPrefix = $self->opts->{api_url};

    my $api_xmlns;
    my $message;
    my $req;
    my $xml;

    #-----------------------------
    # Create new LWP browser
    #-----------------------------
    $::browser = LWP::UserAgent->new(agent => 'perl LWP', cookie_jar => {});

    #-----------------------------
    # LOGIN
    #-----------------------------
    $self->login();
    if ($self->ecode) { return; }
    $api_xmlns = $self->opts->{api_xmlns};
    
    #-----------------------------
    # GET ORGANIZATION
    #-----------------------------
    my $organizationHref = $self->get_organization($urlPrefix);
    if ($self->ecode) { return; }

    #-----------------------------
    # GET VDC
    #-----------------------------
    my $vdcHref = $self->get_vdc($organizationHref);
    if ($self->ecode) { return; }

    #-----------------------------
    # GET VDC INFO
    #-----------------------------
    $xml = $self->get_vdc_info($vdcHref);
    if ($self->ecode) { return; }

    my $xPath = XML::XPath->new($xml);

    #-----------------------------
    # GET VAPP HREF
    #-----------------------------
    $self->debug_msg(5, 'Getting vApp href...');
    my $nodeset  = $xPath->find('/Vdc/ResourceEntities/ResourceEntity');
    my $vAppHref = EMPTY;
    foreach my $node ($nodeset->get_nodelist) {
        if ($node->findvalue('@name')->string_value eq $self->opts->{vcloud_vappname}) {
            $vAppHref = $node->findvalue('@href')->string_value;
            last;
        }
    }

    $self->debug_msg(5, '    vApp href: ' . $vAppHref);

    #-----------------------------
    # GET DESTINATION VDC
    #-----------------------------
    $self->opts->{vcloud_virtual_datacenter} = $self->opts->{vcloud_dest_virtual_datacenter};
    my $destVDCHref = $self->get_vdc($organizationHref);
    if ($self->ecode) { return; }

    #-----------------------------
    # GET DESTINATION VDC INFO
    #-----------------------------
    $xml = $self->get_vdc_info($destVDCHref);
    if ($self->ecode) { return; }
    $xPath = XML::XPath->new($xml);

    #-----------------------------
    # CLONE VAPP HREF
    #-----------------------------
    $self->debug_msg(5, 'Getting Clone vApp href...');
    $nodeset = $xPath->find('/Vdc/Link');
    my $cloneVAppHref = EMPTY;
    foreach my $node ($nodeset->get_nodelist) {
        if (   ($node->findvalue('@rel')->string_value eq 'add')
            && ($node->findvalue('@type')->string_value eq 'application/vnd.vmware.vcloud.cloneVAppParams+xml'))
        {
            $cloneVAppHref = $node->findvalue('@href')->string_value;
            last;
        }
    }
    $self->debug_msg(5, '    Clone vApp href: ' . $cloneVAppHref);

    #-----------------------------
    # CHECK STATUS
    #-----------------------------
    $xml = $self->issue_request("GET", $vAppHref, EMPTY, EMPTY);
    if ($self->ecode) { return; }
    $xPath = XML::XPath->new($xml);

    $nodeset = $xPath->find('/VApp');
    my $node         = $nodeset->get_node(1);
    my $status       = $node->findvalue('@deployed')->string_value;
    my $undeployHref = EMPTY;

    $self->debug_msg(5, 'Getting vApp Undeploy href...');
    $nodeset = $xPath->find('/VApp/Link');
    foreach my $node ($nodeset->get_nodelist) {
        if ($node->findvalue('@rel')->string_value eq 'undeploy') {
            $undeployHref = $node->findvalue('@href')->string_value;
        }
    }
    $self->debug_msg(5, '    vApp Undeploy href: ' . $undeployHref);

    if ($status eq "true") {

        #-----------------------------
        # Undeploy vApp
        #-----------------------------
        $self->debug_msg(1, 'Stopping vApp \'' . $self->opts->{vcloud_vappname} . '\'...');

        $xml = $self->issue_request("POST", $undeployHref, 'application/vnd.vmware.vcloud.undeployVAppParams+xml', "<UndeployVAppParams xmlns=\"$api_xmlns\"/>");
        if ($self->ecode) { return; }
        $xPath = XML::XPath->new($xml);

        #-----------------------------
        # WAIT UNTIL TASK COMPLETES, IS QUEDED, OR RETURNS ERROR
        #-----------------------------
        $nodeset = $xPath->find('/Task');
        my $node     = $nodeset->get_node(1);
        my $taskHref = $node->findvalue('@href')->string_value;

        my $result = $self->wait_task($taskHref);
        if ($self->ecode) { return; }

        if ($result == TASK_SUCCESS) {
            $self->debug_msg(0, 'vApp \'' . $self->opts->{vcloud_vappname} . '\' succesfully undeployed');
        }
        elsif ($result == TASK_ERROR) {
            $self->debug_msg(0, 'Error: Failed to undeploy vApp \'' . $self->opts->{vcloud_vappname} . '\'');
            $self->opts->{exitcode} = ERROR;
            return;
        }
        elsif ($result == TASK_QUEUED) {
            $self->debug_msg(0, 'The task for undeploy vApp \'' . $self->opts->{vcloud_vappname} . '\' has been queued for execution');
        }
    }

    #-----------------------------
    # CLONE VAPP
    #-----------------------------
    $self->debug_msg(1, 'Cloning vApp \'' . $self->opts->{vcloud_vappname} . '\'...');

    $message = '<CloneVAppParams name="' . $self->opts->{vcloud_new_vappname} . '" xmlns="'. $api_xmlns . '"><Description>Cloned with Electric Commander</Description><Source href="' . $vAppHref . '"/><IsSourceDelete>false</IsSourceDelete></CloneVAppParams>';

    $xml = $self->issue_request("POST", $cloneVAppHref, 'application/vnd.vmware.vcloud.cloneVAppParams+xml', $message);
    if ($self->ecode) { return; }
    $xPath = XML::XPath->new($xml);

    #-----------------------------
    # Get new vApp href
    #-----------------------------
    $nodeset = $xPath->find('/VApp');
    $node    = $nodeset->get_node(1);
    my $newVAppHref = $node->findvalue('@href')->string_value;

    #-----------------------------
    # WAIT CLONING TO COMPLETE
    #-----------------------------
    my $taskStatus;
    do {

        #-----------------------------
        # Keep getting the info until status different to 0
        #-----------------------------
        print "...";
        sleep(WAIT_SLEEP_TIME);

        $xml = $self->issue_request("GET", $newVAppHref, EMPTY, EMPTY);
        if ($self->ecode) { return; }
        $xPath = XML::XPath->new($xml);

        $nodeset    = $xPath->find('/VApp');
        $node       = $nodeset->get_node(1);
        $taskStatus = $node->findvalue('@status')->string_value;

    } while ($taskStatus ne "8" && $taskStatus ne "-1");

    #-----------------------------
    # If error
    #-----------------------------
    if ($taskStatus eq "-1") {
        die "error: task status -1";
    }
    print "\n";
    $self->debug_msg(0, 'vApp \'' . $self->opts->{vcloud_vappname} . '\' succesfully cloned to new vApp \'' . $self->opts->{vcloud_new_vappname} . '\'');
    return;
}

###########################################################################

=head2 capture
 
  Title    : capture
  Usage    : $self->capture();
  Function : Create a vApp template from an instantiated vApp.
  Returns  : none
  Args     : none
           :
=cut

###########################################################################
sub capture {
    my $self = shift;

    $self->debug_msg(1, '---------------------------------------------------------------------');
    $self->initialize();
    $self->initialize_prop_prefix;

    my $url;
    my $xml;
     my $urlPrefix = $self->opts->{api_url};

   my $api_xmlns;
    my $message;
    my $req;

    #-----------------------------
    # Create new LWP browser
    #-----------------------------
    $::browser = LWP::UserAgent->new(agent => 'perl LWP', cookie_jar => {});

    #-----------------------------
    # LOGIN
    #-----------------------------
    $self->login();
    if ($self->ecode) { return; }
    $api_xmlns = $self->opts->{api_xmlns};
    
    #-----------------------------
    # GET ORGANIZATION
    #-----------------------------
    my $organizationHref = $self->get_organization($urlPrefix);
    if ($self->ecode) { return; }

    #-----------------------------
    # GET CATALOG
    #-----------------------------
    my $catalogHref = $self->get_catalog($organizationHref);
    if ($self->ecode) { return; }

    #-----------------------------
    # GET VDC
    #-----------------------------
    my $vdcHref = $self->get_vdc($organizationHref);
    if ($self->ecode) { return; }

    #-----------------------------
    # GET VDC INFO
    #-----------------------------
    $xml = $self->get_vdc_info($vdcHref);
    if ($self->ecode) { return; }

    my $xPath = XML::XPath->new($xml);

    #-----------------------------
    # GET VAPP HREF
    #-----------------------------
    $self->debug_msg(5, 'Getting vApp href...');
    my $nodeset  = $xPath->find('/Vdc/ResourceEntities/ResourceEntity');
    my $vAppHref = EMPTY;
    foreach my $node ($nodeset->get_nodelist) {
        if ($node->findvalue('@name')->string_value eq $self->opts->{vcloud_vappname}) {
            $vAppHref = $node->findvalue('@href')->string_value;
            last;
        }
    }

    $self->debug_msg(5, '    vApp href: ' . $vAppHref);

    #-----------------------------
    # GET CAPTURE VAPP HREF
    #-----------------------------
    $self->debug_msg(5, 'Getting Capture vApp href...');
    $nodeset = $xPath->find('/Vdc/Link');
    my $captureVAppHref = EMPTY;
    foreach my $node ($nodeset->get_nodelist) {
        if (   ($node->findvalue('@rel')->string_value eq 'add')
            && ($node->findvalue('@type')->string_value eq 'application/vnd.vmware.vcloud.captureVAppParams+xml'))
        {
            $captureVAppHref = $node->findvalue('@href')->string_value;
            last;
        }
    }
    $self->debug_msg(5, '    Capture vApp href: ' . $captureVAppHref);

    #-----------------------------
    # CHECK STATUS
    #-----------------------------
    $xml = $self->issue_request("GET", $vAppHref, EMPTY, EMPTY);
    if ($self->ecode) { return; }
    $xPath = XML::XPath->new($xml);

    $nodeset = $xPath->find('/VApp');
    my $node         = $nodeset->get_node(1);
    my $status       = $node->findvalue('@deployed')->string_value;
    my $undeployHref = EMPTY;

    if ($status eq "true") {

        $self->debug_msg(5, 'Getting vApp Undeploy href...');
        $nodeset = $xPath->find('/VApp/Link');
        foreach my $node ($nodeset->get_nodelist) {
            if ($node->findvalue('@rel')->string_value eq 'undeploy') {
                $undeployHref = $node->findvalue('@href')->string_value;
            }
        }
        $self->debug_msg(5, '    vApp Undeploy href: ' . $undeployHref);

        #-----------------------------
        # Undeploy vApp
        #-----------------------------
        $self->debug_msg(1, 'Stopping vApp \'' . $self->opts->{vcloud_vappname} . '\'...');

        $xml = $self->issue_request("POST", $undeployHref, 'application/vnd.vmware.vcloud.undeployVAppParams+xml', '<UndeployVAppParams xmlns="'. $api_xmlns . '"/>');
        if ($self->ecode) { return; }
        $xPath = XML::XPath->new($xml);

        #-----------------------------
        # WAIT UNTIL TASK COMPLETES, IS QUEDED, OR RETURNS ERROR
        #-----------------------------
        $nodeset = $xPath->find('/Task');
        my $node     = $nodeset->get_node(1);
        my $taskHref = $node->findvalue('@href')->string_value;

        my $result = $self->wait_task($taskHref);
        if ($self->ecode) { return; }

        if ($result == TASK_SUCCESS) {
            $self->debug_msg(0, 'vApp \'' . $self->opts->{vcloud_vappname} . '\' succesfully undeployed');
        }
        elsif ($result == TASK_ERROR) {
            $self->debug_msg(0, 'Error: Failed to undeploy vApp \'' . $self->opts->{vcloud_vappname} . '\'');
            $self->opts->{exitcode} = ERROR;
            return;
        }
        elsif ($result == TASK_QUEUED) {
            $self->debug_msg(0, 'The task for undeploy vApp \'' . $self->opts->{vcloud_vappname} . '\' has been queued for execution');
        }
    }

    #-----------------------------
    # CAPTURE VAPP
    #-----------------------------
    $self->debug_msg(0, 'Capturing vApp \'' . $self->opts->{vcloud_vappname} . '\' to create template \'' . $self->opts->{vcloud_new_vapp_template_name} . '\'...');

    $message = '<CaptureVAppParams name="' . $self->opts->{vcloud_new_vapp_template_name} . '" xmlns="'.$api_xmlns.'">
        <Description>' . $self->opts->{vcloud_new_vapp_template_desc} . '</Description>
        <Source href="' . $vAppHref . '"/>
    </CaptureVAppParams>';

    $xml = $self->issue_request("POST", $captureVAppHref, 'application/vnd.vmware.vcloud.captureVAppParams+xml', $message);
    if ($self->ecode) { return; }
    $xPath = XML::XPath->new($xml);

    #-----------------------------
    # Get new vApp template href
    #-----------------------------
    my $newVAppHref = $xPath->findvalue('/VAppTemplate/@href')->string_value;

    $self->debug_msg(0, '    vAppTemplate \'' . $self->opts->{vcloud_new_vapp_template_name} . '\' href: ' . $newVAppHref);

    #-----------------------------
    # WAIT CAPTURING TO COMPLETE
    #-----------------------------
    my $taskStatus;
    do {

        #-----------------------------
        # Keep getting the info until status different to 0
        #-----------------------------
        print "...";
        sleep(WAIT_SLEEP_TIME);

        $xml = $self->issue_request("GET", $newVAppHref, EMPTY, EMPTY);
        if ($self->ecode) { return; }
        $xPath      = XML::XPath->new($xml);
        $taskStatus = $xPath->findvalue('/VAppTemplate/@status')->string_value;

    } while ($taskStatus ne "8" && $taskStatus ne "-1" && $taskStatus ne "1");

    #-----------------------------
    # If error
    #-----------------------------
    if ($taskStatus eq "-1") {
        die "status is -1";
    }
    print "\n";

    $self->debug_msg(1, 'Adding vAppTemplate \'' . $self->opts->{vcloud_new_vapp_template_name} . '\' to catalog \'' . $self->opts->{vcloud_catalog} . '\'...');

    $message = '<CatalogItem name="' . $self->opts->{vcloud_new_vapp_template_name} . '" xmlns="'.$api_xmlns.'"><Description>' . $self->opts->{vcloud_new_vapp_template_desc} . '</Description><Entity href="' . $newVAppHref . '"/><Property key="Owner">' . $self->opts->{vclouddirector_user} . '</Property></CatalogItem>';

    $xml = $self->issue_request("POST", $catalogHref . '/catalogItems', 'application/vnd.vmware.vcloud.catalogItem+xml', $message);
    if ($self->ecode) { return; }

    $self->debug_msg(0, 'VApp \'' . $self->opts->{vcloud_vappname} . '\' succesfully captured to new vApp Template\'' . $self->opts->{vcloud_new_vapp_template_name} . '\'');
    return;
}

###########################################################################

=head2 get_vapp
 
  Title    : get_vapp
  Usage    : $self->get_vapp();
  Function : Get information for a vApp
  Returns  : none
  Args     : none
           :
=cut

###########################################################################
sub get_vapp {
    my $self = shift;

    $self->debug_msg(1, '---------------------------------------------------------------------');
    $self->initialize();
    $self->initialize_prop_prefix;
    if ($self->ecode) { return; }

    my $url;
    my $message;
    my $xml;
   my $urlPrefix = $self->opts->{api_url};

   my $api_xmlns;
    my $result;
    my $req;

    #-----------------------------
    # Create new LWP browser
    #-----------------------------
    $::browser = LWP::UserAgent->new(agent => 'perl LWP', cookie_jar => {});

    #-----------------------------
    # LOGIN
    #-----------------------------
    $self->login();
    if ($self->ecode) { return; }
    $api_xmlns = $self->opts->{api_xmlns};
    
    #-----------------------------
    # GET ORGANIZATION
    #-----------------------------
    my $organizationHref = $self->get_organization($urlPrefix);
    if ($self->ecode) { return; }

    #-----------------------------
    # GET VDC
    #-----------------------------
    my $vdcHref = $self->get_vdc($organizationHref);
    if ($self->ecode) { return; }

    #-----------------------------
    # GET VDC INFO
    #-----------------------------
    $xml = $self->get_vdc_info($vdcHref);
    if ($self->ecode) { return; }

    my $xPath = XML::XPath->new($xml);

    #-----------------------------
    # GET VAPP INFO
    #-----------------------------
    $self->debug_msg(5, 'Getting vApp href...');
    my $nodeset  = $xPath->find('/Vdc/ResourceEntities/ResourceEntity');
    my $vAppHref = EMPTY;
    foreach my $node ($nodeset->get_nodelist) {
        if ($node->findvalue('@name')->string_value eq $self->opts->{vcloud_vappname}) {
            $vAppHref = $node->findvalue('@href')->string_value;
            last;
        }
    }
    if ($vAppHref eq EMPTY) {
        $self->debug_msg(0, '    vApp: ' . $self->opts->{vcloud_vappname} . ' not found.');
        $self->opts->{exitcode} = ERROR;
        $self->set_prop("/command_error", 'vApp: ' . $self->opts->{vcloud_vappname} . ' not found.');
        return;
    }
    if ($self->ecode) { return; }

    $self->debug_msg(5, '    vApp href: ' . $vAppHref);

    $xml = $self->issue_request("GET", $vAppHref, EMPTY, EMPTY);
    if ($self->ecode) { return; }
    $xPath = XML::XPath->new($xml);

    my $setResult = $self->set_prop("/vApp", $xml);

    return;
}

###########################################################################

=head2 start_vapp
 
  Title    : start_vapp
  Usage    : $self->start_vapp();
  Function : Deploy/Power On a vApp.
  Returns  : none
  Args     : none
           :
=cut

###########################################################################
sub start_vapp {
    my $self = shift;

    $self->debug_msg(1, '---------------------------------------------------------------------');
    $self->initialize();
    $self->initialize_prop_prefix;

    my $url;
    my $urlPrefix = $self->opts->{api_url};

   my $api_xmlns;
    my $message;
    my $req;
    my $xml;

    #-----------------------------
    # Create new LWP browser
    #-----------------------------
    $::browser = LWP::UserAgent->new(agent => 'perl LWP', cookie_jar => {});

    #-----------------------------
    # LOGIN
    #-----------------------------
    $self->login();
    if ($self->ecode) { return; }
    $api_xmlns = $self->opts->{api_xmlns};
    
    #-----------------------------
    # GET ORGANIZATION
    #-----------------------------
    my $organizationHref = $self->get_organization($urlPrefix);
    if ($self->ecode) { return; }

    #-----------------------------
    # GET VDC
    #-----------------------------
    my $vdcHref = $self->get_vdc($organizationHref);
    if ($self->ecode) { return; }

    #-----------------------------
    # GET VDC INFO
    #-----------------------------
    $xml = $self->get_vdc_info($vdcHref);
    if ($self->ecode) { return; }

    my $xPath = XML::XPath->new($xml);

    #-----------------------------
    # GET VAPP HREF
    #-----------------------------
    $self->debug_msg(5, 'Getting vApp href...');
    my $nodeset  = $xPath->find('/Vdc/ResourceEntities/ResourceEntity');
    my $vAppHref = EMPTY;
    foreach my $node ($nodeset->get_nodelist) {
        if ($node->findvalue('@name')->string_value eq $self->opts->{vcloud_vappname}) {
            $vAppHref = $node->findvalue('@href')->string_value;
            last;
        }
    }
    if ($vAppHref eq EMPTY) {
        $self->debug_msg(0, '    vApp: ' . $self->opts->{vcloud_vappname} . ' not found.');
        $self->opts->{exitcode} = ERROR;
        $self->set_prop("/command_error", 'vApp: ' . $self->opts->{vcloud_vappname} . ' not found.');
        return;
    }
    if ($self->ecode) { return; }

    my $deploy_href_found = 0;
    my $counter = 0;
    my $deployHref;
    until ($deploy_href_found) {
        $self->debug_msg(5, '    vApp href: ' . $vAppHref);

        $xml = $self->issue_request("GET", $vAppHref, EMPTY, EMPTY);
        if ($self->ecode) { return; }
        $xPath = XML::XPath->new($xml);

        #-----------------------------
        # Get deploy href for the vApp
        #-----------------------------
        # my $deployHref;
        $self->debug_msg(5, 'Getting Deploy vApp href...');
        $nodeset = $xPath->find('/VApp/Link');
        $deployHref = $self->extractDeployHref($nodeset);
        $counter++;
        if ($deployHref || $counter > 10) {
            $deploy_href_found++;
        }
        else {
            print "deploy href wasn't found. Will try again\n";
            sleep 5;
        }
    }
    if (!$deployHref) {
        print "deploy href wasn't found. Aborting";
        exit 1;
    }
    # foreach my $node ($nodeset->get_nodelist) {
    #     if ($node->findvalue('@rel')->string_value eq 'deploy') {
    #         $deployHref = $node->findvalue('@href')->string_value;
    #         last;
    #     }
    # }
    $self->debug_msg(5, '    Deploy vApp href: ' . $deployHref);

    #-----------------------------
    # DEPLOY AND POWER ON THE VAPP
    #-----------------------------
    $self->debug_msg(1, 'Deploying vApp \'' . $self->opts->{vcloud_vappname} . '\'...');

    $message = "<DeployVAppParams powerOn=\"true\" deploymentLeaseSeconds=\"2592000\" xmlns=\"$api_xmlns\"/>";

    $xml = $self->issue_request("POST", $deployHref, 'application/vnd.vmware.vcloud.deployVAppParams+xml', $message);
    if ($self->ecode) { return; }
    $xPath = XML::XPath->new($xml);

    #-----------------------------
    # WAIT UNTIL TASK COMPLETES, IS QUEDED, OR RETURNS ERROR
    #-----------------------------
    $nodeset = $xPath->find('/Task');
    my $node    = $nodeset->get_node(1);
    my $taskHref = $node->findvalue('@href')->string_value;

    my $result = $self->wait_task($taskHref);
    if ($self->ecode) { return; }

    if ($result == TASK_SUCCESS) {
        $self->debug_msg(0, 'vApp \'' . $self->opts->{vcloud_vappname} . '\' succesfully deployed');
    }
    elsif ($result == TASK_ERROR) {
        $self->debug_msg(0, 'Error: Failed to deploy vApp \'' . $self->opts->{vcloud_vappname} . '\'');
        $self->opts->{exitcode} = ERROR;

    }
    elsif ($result == TASK_QUEUED) {
        $self->debug_msg(0, 'The task for the deployment of vApp \'' . $self->opts->{vcloud_vappname} . '\' has been queued for execution');
    }

    #-----------------------------
    #STORE RESULTS ON PROPERTIES
    #-----------------------------
    $self->store_properties($vAppHref);
    if ($self->ecode) { return; }
    return;
}

# -------------------------------------------------------------------------
# Helper functions
# -------------------------------------------------------------------------

###########################################################################

=head2 my_cmdr
 
  Title    : my_cmdr
  Usage    : $self->my_cmdr();
  Function : Get ElectricCommander instance.
  Returns  : ElectricCommander instance asociated to vCloudDirector
  Args     : none
           :
=cut

###########################################################################
sub my_cmdr {
    my $self = shift;
    return $self->{_cmdr};
}

###########################################################################

=head2 opts
 
  Title    : opts
  Usage    : $self->opts();
  Function : Get opts hash.
  Returns  : opts hash
  Args     : named arguments:
           : none
           :
=cut

###########################################################################
sub opts {
    my $self = shift;
    return $self->{_opts};
}

###########################################################################

=head2 my_prop
 
  Title    : my_prop
  Usage    : $self->my_prop();
  Function : Get PropDB.
  Returns  : PropDB
  Args     : named arguments:
           : none
           :
=cut

###########################################################################
sub my_prop {
    my $self = shift;
    return $self->{_props};
}

###########################################################################

=head2 set_prop
 
  Title    : set_prop
  Usage    : $self->set_prop();
  Function : Use stored property prefix and PropDB to set a property.
  Returns  : setResult => result returned by PropDB->setProp
  Args     : named arguments:
           : -location => relative location to set the property
           : -value    => value of the property
           :
=cut

###########################################################################
sub set_prop {
    my $self     = shift;
    my $location = shift;
    my $value    = shift;

    my $setResult = $self->my_prop->setProp($self->opts->{PropPrefix} . $location, $value);
    return $setResult;
}

###########################################################################

=head2 get_prop
 
  Title    : get_prop
  Usage    : $self->get_prop();
  Function : Use stored property prefix and PropDB to get a property.
  Returns  : getResult => property value
  Args     : named arguments:
           : -location => relative location to get the property
           :
=cut

###########################################################################
sub get_prop {
    my $self     = shift;
    my $location = shift;

    my $getResult = $self->my_prop->getProp($self->opts->{PropPrefix} . $location);
    return $getResult;
}

###########################################################################

=head2 delete_prop
 
  Title    : delete_prop
  Usage    : $self->delete_prop();
  Function : Use stored property prefix and PropDB to delete a property.
  Returns  : delResult => result returned by PropDB->deleteProp
  Args     : named arguments:
           : -location => relative location of the property to delete
           :
=cut

###########################################################################
sub delete_prop {
    my $self     = shift;
    my $location = shift;

    my $delResult = $self->my_prop->deleteProp($self->opts->{PropPrefix} . $location);
    return $delResult;
}

###########################################################################

=head2 initialize
 
  Title    : initialize
  Usage    : $self->initialize();
  Function : Set initial values.
  Returns  : none
  Args     : named arguments:
           : none
           :
=cut

###########################################################################
sub initialize {
    my $self = shift;

    binmode STDOUT, ':encoding(utf8)';
    binmode STDIN,  ':encoding(utf8)';
    binmode STDERR, ':encoding(utf8)';

    $self->{_props} = new ElectricCommander::PropDB($self->my_cmdr(), EMPTY);

    # Set defaults
    if ($self->opts->{debug} ne EMPTY) {
        $::gDebug = $self->opts->{debug};
    }
    else {
        $self->opts->{debug} = DEFAULT_DEBUG;
    }
    
    if ($self->opts->{api_version} eq EMPTY) {
        $self->opts->{api_version} = DEFAULT_API_VERSION;
    }
    
    my $url = $self->opts->{vclouddirector_url};
    if ($self->opts->{api_login} eq EMPTY) {
        $self->opts->{api_login} = $url . DEFAULT_API_LOGIN;
    }
    
    $self->opts->{api_login} =~ s/^.+\/api\//$url\/api\//;
    $self->opts->{api_url} = $self->opts->{api_login}; 
    $self->opts->{api_url}=~ s/\/[a-z]+$//;
    
    my $api_version = $self->opts->{api_version};
    $self->opts->{api_xmlns} = "http://www.vmware.com/vcloud/v$api_version";
    
    $self->opts->{exitcode}           = SUCCESS;
    $self->opts->{JobId}              = $ENV{COMMANDER_JOBID};

    return;
}

###########################################################################

=head2 initialize_prop_prefix
 
  Title    : initialize_prop_prefix
  Usage    : $self->initialize_prop_prefix();
  Function : Initialize PropPrefix value and check valid location
  Returns  : none
  Args     : none
           :
=cut

###########################################################################
sub initialize_prop_prefix {
    my $self = shift;

    # setup the property sheet where information will be exchanged
    if (!defined($self->opts->{results}) || $self->opts->{results} eq EMPTY) {
        if ($self->opts->{JobStepId} ne "1") {
            $self->opts->{results} = DEFAULT_LOCATION;    # default location to save properties
            $self->debug_msg(5, "Using default location for results");
        }
        else {
            $self->debug_msg(0, "Must specify property sheet location when not running in job");
            $self->opts->{exitcode} = ERROR;
            return;
        }
    }
    $self->opts->{PropPrefix} = $self->opts->{results};
    if (defined($self->opts->{tag}) && $self->opts->{tag} ne EMPTY) {
        $self->opts->{PropPrefix} .= "/" . $self->opts->{tag};
    }
    $self->debug_msg(5, "Results will be in:" . $self->opts->{PropPrefix});

    # test that the location is valid
    if ($self->check_valid_location) {
        $self->opts->{exitcode} = ERROR;
        return;
    }
}

###########################################################################

=head2 check_valid_location
 
  Title    : check_valid_location
  Usage    : $self->check_valid_location();
  Function : Check if location specified in PropPrefix is valid
  Returns  : 0 - Success
           : 1 - Error
  Args     : none
           :
=cut

###########################################################################
sub check_valid_location {
    my $self     = shift;
    my $location = "/test-" . $self->opts->{JobStepId};

    # Test set property in location
    my $result = $self->set_prop($location, "Test property");
    if (!defined($result) || $result eq EMPTY) {
        $self->debug_msg(0, "Invalid location: " . $self->opts->{PropPrefix});
        return ERROR;
    }

    # Test get property in location
    $result = $self->get_prop($location);
    if (!defined($result) || $result eq EMPTY) {
        $self->debug_msg(0, "Invalid location: " . $self->opts->{PropPrefix});
        return ERROR;
    }

    # Delete property
    $result = $self->delete_prop($location);
    return SUCCESS;
}

###########################################################################

=head2 ecode
 
  Title    : ecode
  Usage    : $self->ecode();
  Function : Get exit code
  Returns  : exit code number
  Args     : none
           :
=cut

###########################################################################
sub ecode {
    my $self = shift;
    return $self->opts()->{exitcode};
}

###########################################################################

=head2 login
 
  Title    : login
  Usage    : $self->login();
  Function : Login to vCloud Director
  Returns  : none
  Args     : none
           :
=cut

###########################################################################
sub login {
    my $self      = shift;

    my $xml;
    my $xPath;
    my $loginUrl = $self->opts->{api_login};

    #-----------------------------
    # LOGIN
    #-----------------------------
    my $url = URI->new($loginUrl);
    $self->debug_msg(1, 'Log in to  \'' . $loginUrl . '\'');

    #-----------------------------
    # Post to url, included authentication string to get session token
    #-----------------------------
    my $req = HTTP::Request->new(POST => $url);

    #-----------------------------
    # Set authentication string, format is username@hostingacct:password
    #-----------------------------
    $req->authorization_basic($self->opts->{vclouddirector_user} . '@' . $self->opts->{vclouddirector_conf_org}, $self->opts->{vclouddirector_pass});

    $req->header('Accept', 'application/*+xml;version=' . $self->opts->{api_version}); 
    
    $self->debug_msg(6, "\nRequest:" . $req->as_string);
    my $response = $::browser->request($req);
    $self->debug_msg(6, "\nResponse:" . $response->content);

    $self->debug_msg(1, "    Authentication status: " . $response->status_line);

    #-----------------------------
    # Check if successful login
    #-----------------------------
    if ($response->is_error) {
        $self->debug_msg(0, $response->status_line);
        $self->get_error_by_code($response->code, $response->message);
        $self->opts->{exitcode} = ERROR;
        return;
    }
    
    $xPath = XML::XPath->new($response->content);
    my $xmlns =  $xPath->{_xml};
    if($xmlns =~ m/xmlns="([^"]+)"\s/)
    {  
        $self->opts->{api_xmlns} = $1;
    }
    return;
}


###########################################################################

=head2 get_organization
 
  Title    : get_organization
  Usage    : $self->get_organization();
  Function : Get organization url
  Returns  : organizationHref - organization href
  Args     : urlString      => string to create the url
           :
=cut

###########################################################################
sub get_organization {
# GET API-URL/org

    my $self      = shift;
    my $urlString = shift;

    my $xml;
    my $xPath;
    my $apiurl = $urlString;
    # $urlString .= '/login';
    $urlString .= '/org';

    #-----------------------------
    # LOGIN
    #-----------------------------
    my $url = URI->new($urlString);
    #$self->debug_msg(1, 'Log in to  \'' . $urlString . '\'');

    #-----------------------------
    # Post to url, included authentication string to get session token
    #-----------------------------
    #my $req = HTTP::Request->new(POST => $url);
    my $req = HTTP::Request->new(GET => $url);
    $req->header('Accept', 'application/*+xml;version=' . $self->opts->{api_version}); 
    #-----------------------------
    # Set authentication string, format is username@hostingacct:password
    #-----------------------------
    #$req->authorization_basic($self->opts->{vclouddirector_user} . '@' . $self->opts->{vclouddirector_conf_org}, $self->opts->{vclouddirector_pass});

    $self->debug_msg(6, "\nRequest:" . $req->as_string);
    my $response = $::browser->request($req);
    $self->debug_msg(6, "\nResponse:" . $response->content);

    # $self->debug_msg(1, "    Authentication status: " . $response->status_line);

    #-----------------------------
    # Check if successful request
    #-----------------------------
    if ($response->is_error) {
        $self->debug_msg(0, $response->status_line);
        $self->get_error_by_code($response->code, $response->message);
        $self->opts->{exitcode} = ERROR;
        return;
    }
    
    $xml = $response->content;
    if ($xml =~ /vcloud:/) {
        #print "fixing XML vcloud: tags\n";
        $xml =~ s/vcloud://g;
    }

    #-----------------------------
    #Get organization url
    #-----------------------------
    if ($self->opts->{vcloud_organization} eq 'System') {
        $self->debug_msg(5, 'Getting System organization url...');

        $xml = $self->issue_request("GET", $apiurl . '/org/1', EMPTY, EMPTY);
        if ($self->ecode) { return; }
    }

    $xPath = XML::XPath->new($xml);
    $self->debug_msg(5, 'Getting organization url...');
    my $organizationHref = EMPTY;
    
    
    my $nodeset          = $xPath->find('/OrgList/Org');

    foreach my $node ($nodeset->get_nodelist) {
        if ($node->findvalue('@name')->string_value eq $self->opts->{vcloud_organization}) {
            $organizationHref = $node->findvalue('@href')->string_value;
            last;
        }
    }

    $self->debug_msg(5, '    Organization url: ' . $organizationHref);
    return $organizationHref;
}

###########################################################################

=head2 get_catalog
 
  Title    : get_catalog
  Usage    : $self->get_catalog();
  Function : Get catalog href
  Returns  : catalogHref - catalog href
  Args     : urlString      => string to create the url
           :
=cut

###########################################################################
sub get_catalog {
    my $self      = shift;
    my $urlString = shift;

    $self->debug_msg(5, 'Getting Catalog url...');

    my $xml = $self->issue_request("GET", $urlString, EMPTY, EMPTY);
    if ($self->ecode) { return; }
    my $xPath = XML::XPath->new($xml);

    my $catalogHref = EMPTY;
    my $nodeset     = $xPath->find('/Org /Link');

    foreach my $node ($nodeset->get_nodelist) {
        if (   $node->findvalue('@name')->string_value eq $self->opts->{vcloud_catalog}
            && $node->findvalue('@type')->string_value eq 'application/vnd.vmware.vcloud.catalog+xml')
        {
            $catalogHref = $node->findvalue('@href')->string_value;
            last;
        }
    }

    if ($catalogHref eq EMPTY) {
        $self->debug_msg(0, "    Catalog '" . $self->opts->{vcloud_catalog} . "' not found in organization " . $self->opts->{vcloud_organization});
        $self->opts->{exitcode} = ERROR;
        return;
    }

    $self->debug_msg(5, '   Catalog url:  ' . $catalogHref);
    return $catalogHref;

}

###########################################################################

=head2 get_vdc
 
  Title    : get_vdc
  Usage    : $self->get_vdc();
  Function : Get vdc href
  Returns  : vdcHref - vdc href
  Args     : urlString      => string to create the url
           :
=cut

###########################################################################
sub get_vdc {
    my $self      = shift;
    my $urlString = shift;

    $self->debug_msg(5, 'Getting VDC url...');
    my $xml = $self->issue_request("GET", $urlString, EMPTY, EMPTY);
    if ($self->ecode) { return; }
    my $xPath = XML::XPath->new($xml);

    my $vdcHref = EMPTY;
    my $nodeset = $xPath->find('/Org /Link');
    $self->debug_msg(6, "Looking for VDC [" . $self->opts->{vcloud_virtual_datacenter} . "] in organization [" . $self->opts->{vcloud_organization} . "]");
    $self->debug_msg(6, "XML:" . $xPath->{_xml});

    foreach my $node ($nodeset->get_nodelist) {
        my $name = $node->findvalue('@name')->string_value;
        my $type = $node->findvalue('@type')->string_value;
        $self->debug_msg(6, "comparing [$name] with type [$type]");
        if (   $name eq $self->opts->{vcloud_virtual_datacenter}
            && $type eq 'application/vnd.vmware.vcloud.vdc+xml')
        {
            $self->debug_msg(6, "found!");
            $vdcHref = $node->findvalue('@href')->string_value;
            last;
        }
    }

    if ($vdcHref eq EMPTY) {
        $self->debug_msg(0, "    VDC '" . $self->opts->{vcloud_virtual_datacenter} . "' not found in organization " . $self->opts->{vcloud_organization});
        $self->opts->{exitcode} = ERROR;
        return;
    }

    $self->debug_msg(5, '    VDC url: ' . $vdcHref);
    return $vdcHref;

}

###########################################################################

=head2 get_template
 
  Title    : get_template
  Usage    : $self->get_template();
  Function : Get template href
  Returns  : templateHref - template href
  Args     : urlString      => string to create the url
           :
=cut

###########################################################################
sub get_template {
    my $self      = shift;
    my $urlString = shift;

    $self->debug_msg(5, 'Getting Template url...');

    my $xml = $self->issue_request("GET", $urlString, EMPTY, EMPTY);
    if ($self->ecode) { return; }
    my $xPath = XML::XPath->new($xml);

    my $templateHref = EMPTY;
    my $nodeset      = $xPath->find('/Vdc/ResourceEntities/ResourceEntity');

    foreach my $node ($nodeset->get_nodelist) {
        my $name = $node->findvalue('@name')->string_value;
        my $type = $node->findvalue('@type')->string_value;
        $self->debug_msg(6, "comparing [$name]  type [$type]");
        if (   $name eq $self->opts->{vcloud_template}
            && $type eq 'application/vnd.vmware.vcloud.vAppTemplate+xml')
        {
            $self->debug_msg(6, "found!");
            $templateHref = $node->findvalue('@href')->string_value;
            last;
        }
    }

    if ($self->opts->{vcloud_catalog_href} && $templateHref eq EMPTY) {
        $self->debug_msg(6, "Template wasn't found in VDC, searching into catalog");
        my $response = $self->issue_request(
            GET => $self->opts->{vcloud_catalog_href},
            '',''
        );
        if (!$response) {
            die "Can't get catalog data";
        }
        my $xml_object = XMLin_safe($response);
        for my $template_name (keys %{$xml_object->{CatalogItems}->{CatalogItem}}) {
            if ($template_name eq $self->opts->{vcloud_template}) {
                $self->debug_msg(6, 'Template ' . $template_name . ' found in catalog');
                my $temp = $xml_object->{CatalogItems}->{CatalogItem}->{$template_name}->{href};
                $self->debug_msg(6, "CatalogItem url: $temp");
                my $catalog_item_xml = $self->issue_request(GET => $temp, '', '');
                $self->debug_msg(6, "CatalogItem XML: $catalog_item_xml");
                my $catalog_item_data = XMLin_safe($catalog_item_xml);
                if ($catalog_item_data && $catalog_item_data->{Entity}->{href}) {
                    $templateHref = $catalog_item_data->{Entity}->{href};
                }
                last;
            }
        }
        if (!$templateHref) {
            if ($xml_object->{CatalogItems}->{CatalogItem}->{name} eq $self->opts->{vcloud_template}) {
                $templateHref = $xml_object->{CatalogItems}->{CatalogItem}->{href};
            }
        }
    }

    if ($templateHref eq EMPTY) {
        $self->debug_msg(0, "    Template '" . $self->opts->{vcloud_template} . "' not found in catalog " . $self->opts->{vcloud_catalog});
        $self->opts->{exitcode} = ERROR;
        return;
    }

    $self->debug_msg(5, '    Template url: ' . $templateHref);
    return $templateHref;
}

###########################################################################

=head2 get_vdc_info
 
  Title    : get_vdc_info
  Usage    : $self->get_vdc_info();
  Function : Get VDC response
  Returns  : xml - vdc response
  Args     : urlString      => string to create the url
           :
=cut

###########################################################################
sub get_vdc_info {
    my $self      = shift;
    my $urlString = shift;

    $self->debug_msg(5, 'Getting VDC Information...');

    my $xml = $self->issue_request("GET", $urlString, EMPTY, EMPTY);
    if ($self->ecode) { return EMPTY; }

    return $xml;
}

###########################################################################

=head2 wait_task
 
  Title    : wait_task
  Usage    : $self->wait_task();
  Function : Waits for a task to complete
  Returns  : 1 - tasks completed succesfully
           : 2 - tasks completed with errors
           : 3 - tasks queued
  Args     : urlString      => string to create the url
           :
=cut

###########################################################################
sub wait_task {
    my $self      = shift;
    my $urlString = shift;

    my $response;
    my $req;
    my $xPath;
    my $url = URI->new($urlString);
    my $nodeset;
    my $node;

    while (1) {
        my $xml = $self->issue_request("GET", $urlString, EMPTY, EMPTY);
        if ($self->ecode) { return; }
        $xPath = XML::XPath->new($xml);

        $nodeset = $xPath->find('/Task');
        $node    = $nodeset->get_node(1);

        if ($node->findvalue('@status')->string_value eq 'success') {
            return TASK_SUCCESS;
        }
        elsif ($node->findvalue('@status')->string_value eq 'error') {
            return TASK_ERROR;
        }
        elsif ($node->findvalue('@status')->string_value eq 'queued') {
            return TASK_QUEUED;
        }

        #-----------------------------
        # Still running
        #-----------------------------
        sleep(WAIT_SLEEP_TIME);
    }
    return;
}

###########################################################################

=head2 create_resource
 
  Title    : create_resource
  Usage    : $self->create_resource();
  Function : Create Commander resource and save information in properties
  Returns  : none
  Args     : resourceName     => Name for the new resource
           : vmName           => Name of the virtual machine
           : ip_address       => ip address for the virtual machine
           :
=cut

###########################################################################
sub create_resource {
    my $self         = shift;
    my $resourceName = shift;
    my $vmName       = shift;
    my $ip_address   = shift;

    my %failedMachines = ();

    #-----------------------------
    # Append a generated pool name to any specified
    #-----------------------------
    my $pool = $self->opts->{vclouddirector_pools} . " EC-" . $self->opts->{JobStepId};

    #-----------------------------
    #Create resource
    #-----------------------------
    $self->debug_msg(1, 'Creating resource for virtual machine \'' . $vmName . '\'...');
    my $cmdrresult = $self->my_cmdr()->createResource(
                                                      $resourceName,
                                                      {
                                                         description => "vCloudDirector created resource for " . $vmName,
                                                         hostName    => $ip_address,
                                                         pools       => $pool
                                                      }
                                                     );

    #-----------------------------
    # Check for error return
    #-----------------------------
    my $errMsg = $self->my_cmdr()->checkAllErrors($cmdrresult);
    if ($errMsg ne EMPTY) {
        $self->debug_msg(1, "Error: $errMsg");
        $self->opts->{exitcode} = ERROR;
        $failedMachines{$ip_address} = 1;
        return;
    }

    $self->debug_msg(1, 'Resource created');

    #-------------------------------------
    # Record the resource name created
    #-------------------------------------
    my $setResult = $self->set_prop("/resources/" . $resourceName . "/resName", $resourceName);

    #-------------------------------------
    # Add the resource name to InstanceList
    #-------------------------------------
    if ("$::instlist" ne EMPTY) { $::instlist .= ";"; }
    $::instlist .= "$resourceName";
    $self->debug_msg(1, "Adding $resourceName to instance list");

    #-------------------------------------
    # Add the resource name to vm properties
    #-------------------------------------
    $setResult = $self->set_prop("/" . $resourceName . "/Resource", $resourceName);

    #-------------------------------------
    # Wait for resource to respong to ping
    #-------------------------------------
    # If creation of resource failed, do not ping
    if (!defined($failedMachines{$ip_address}) || $failedMachines{ $ip_address == 0 }) {

        my $resStarted = 0;
        my $try        = DEFAULT_PING_TIMEOUT;
        while ($try > 0) {
            $self->debug_msg(1, "Waiting for ping response #(" . $try . ") of resource " . $resourceName . " with IP " . $ip_address);
            my $pingresult = $self->ping_resource($resourceName);
            if ($pingresult == 1) {
                $resStarted = 1;
                last;
            }
            sleep(5);
            $try -= 1;
        }
        if ($resStarted == 0) {
            $self->debug_msg(1, 'Unable to ping virtual machine');
            $self->opts->{exitcode} = ERROR;
        }
        else {
            $self->debug_msg(1, 'Ping response succesfully received');

            $self->debug_msg(0, "Created resource for '$vmName' as " . $resourceName);
        }
    }
}

###########################################################################

=head2 get_deployed_resource_list
 
  Title    : get_deployed_resource_list
  Usage    : $self->get_deployed_resource_list();
  Function : Read the list of configurations deployed for a tag
  Returns  : resources - array of resources on success, empty array on failure 
  Args     : none
           :
=cut

###########################################################################
sub get_deployed_resource_list {
    my $self = shift;

    my @resources = ();

    my $propPrefix = $self->opts->{PropPrefix};

    $self->debug_msg(2, "Finding resources recorded in path " . $propPrefix);

    my $xPath = $self->my_cmdr()->getProperties(
                                                {
                                                  path      => $propPrefix,
                                                  "recurse" => "1"
                                                }
                                               );

    my $nodeset = $xPath->find('//property[propertyName="resources"]/propertySheet/property');

    foreach my $node ($nodeset->get_nodelist) {

        my $propertyName = $xPath->findvalue('propertyName', $node)->string_value;
        my $resName = $xPath->findvalue('//property[propertyName="' . $propertyName . '"]/propertySheet/property[propertyName="resName"]/value', $node)->string_value;
        if ($resName ne EMPTY) {
            $self->debug_msg(1, "Found deployed resource " . $resName);
            push @resources, $resName;
        }
    }
    return @resources;
}

###########################################################################

=head2 ping_resource
 
  Title    : ping_resource
  Usage    : $self->ping_resource();
  Function : Use commander to ping a resource
  Returns  : 1 - alive
           : 0 - not alive
  Args     : -resource => resource name
           :
=cut

###########################################################################
sub ping_resource {
    my $self     = shift;
    my $resource = shift;

    my $alive  = "0";
    my $result = $self->my_cmdr()->pingResource($resource);
    if (!$result) { return NOT_ALIVE; }
    $alive = $result->findvalue('//alive')->string_value;
    if ($alive eq ALIVE) { return ALIVE; }
    return NOT_ALIVE;
}

###########################################################################

=head2 store_properties
 
  Title    : store_properties
  Usage    : $self->store_properties();
  Function : Save Vm information in properties
  Returns  : none
  Args     : -vAppHref => API url for the vApp
           :
=cut

###########################################################################
sub store_properties {
    my $self     = shift;
    my $vAppHref = shift;

    $::instlist = EMPTY;

    my $setResult;
    my $vmHref;
    my $vmName;
    my $ipaddress;
    my $externalipaddress;
    my $vmNetworkName;
    my $vmMac;
    my $vmIsConnected;

    my $xml = $self->issue_request("GET", $vAppHref, EMPTY, EMPTY);
    if ($self->ecode) { return; }
    my $xPath = XML::XPath->new($xml);

    my $nodeset   = $xPath->find('/VApp/Children/Vm');
    my $vm_number = 1;
    foreach my $node ($nodeset->get_nodelist) {

        $self->debug_msg(1, '---------------------------------------------------------------------');

        $vmName = $node->findvalue('@name')->string_value;
        $self->debug_msg(1, 'Getting information of virtual machine \'' . $vmName . '\'...');
        $self->debug_msg(1, 'Storing properties...');

        $setResult = $self->set_prop("/" . $vmName . "-" . $self->opts->{JobId} . "-" . $self->opts->{tag} . "/Name", $vmName);
        $self->debug_msg(1, 'VM: ' . $vmName);

        $vmHref = $node->findvalue('@href')->string_value;
        $setResult = $self->set_prop("/" . $vmName . "-" . $self->opts->{JobId} . "-" . $self->opts->{tag} . "/href", $vmHref);
        $self->debug_msg(1, 'Href: ' . $vmHref);

        $vmNetworkName = $node->findvalue('NetworkConnectionSection/NetworkConnection/@network')->string_value;
        $setResult = $self->set_prop("/" . $vmName . "-" . $self->opts->{JobId} . "-" . $self->opts->{tag} . "/Network", $vmNetworkName);
        $self->debug_msg(1, 'Network: ' . $vmNetworkName);

        $ipaddress = $node->findvalue('NetworkConnectionSection/NetworkConnection/IpAddress')->string_value;
        $setResult = $self->set_prop("/" . $vmName . "-" . $self->opts->{JobId} . "-" . $self->opts->{tag} . "/IpAddress", $ipaddress);
        $self->debug_msg(1, 'IP address: ' . $ipaddress);

        $externalipaddress = $node->findvalue('NetworkConnectionSection/NetworkConnection/ExternalIpAddress')->string_value;
        $setResult = $self->set_prop("/" . $vmName . "-" . $self->opts->{JobId} . "-" . $self->opts->{tag} . "/ExternalIpAddress", $externalipaddress);
        $self->debug_msg(1, 'External IP address: ' . $externalipaddress);

        $vmMac = $node->findvalue('NetworkConnectionSection/NetworkConnection/MACAddress')->string_value;
        $setResult = $self->set_prop("/" . $vmName . "-" . $self->opts->{JobId} . "-" . $self->opts->{tag} . "/MACAddress", $vmMac);
        $self->debug_msg(1, 'Mac address: ' . $vmMac);

        $vmIsConnected = $node->findvalue('NetworkConnectionSection/NetworkConnection/IsConnected')->string_value;
        $setResult = $self->set_prop("/" . $vmName . "-" . $self->opts->{JobId} . "-" . $self->opts->{tag} . "/IsConnected", $vmIsConnected);
        $self->debug_msg(1, 'IsConnected: ' . $vmIsConnected);

        $setResult = $self->set_prop("/" . $vmName . "-" . $self->opts->{JobId} . "-" . $self->opts->{tag} . "/vApp", $self->opts->{vcloud_vappname});
        $self->debug_msg(1, 'vApp: ' . $self->opts->{vcloud_vappname});

        $setResult = $self->set_prop("/" . $vmName . "-" . $self->opts->{JobId} . "-" . $self->opts->{tag} . "/Org", $self->opts->{vcloud_organization});
        $self->debug_msg(1, 'Organization: ' . $self->opts->{vcloud_organization});

        $setResult = $self->set_prop("/" . $vmName . "-" . $self->opts->{JobId} . "-" . $self->opts->{tag} . "/VDC", $self->opts->{vcloud_virtual_datacenter});
        $self->debug_msg(1, 'VDC: ' . $self->opts->{vcloud_virtual_datacenter});

        if($self->opts->{vcloud_create_resource} eq 1) {
            if ($externalipaddress ne EMPTY) {
                $self->create_resource($vmName . "-" . $self->opts->{JobId} . "-" . $self->opts->{tag}, $vmName, $externalipaddress);
                if ($self->ecode) {
                    return;
                }
            }
            elsif($ipaddress ne EMPTY) {
                $self->create_resource($vmName . "-" . $self->opts->{JobId} . "-" . $self->opts->{tag}, $vmName, $ipaddress);
                if ($self->ecode) {
                    return;
                }
            }
            else {
                $self->debug_msg(1, "Cannot create resource for '" . $vmName . "': empty IP address");
            }
        }
        $vm_number++;
    }
    $self->debug_msg(1, "Saving vm list " . $::instlist);
    $self->set_prop("/VMList", $::instlist);
}

###########################################################################

=head2 debug_msg
 
  Title    : debug_msg
  Usage    : $self->debug_msg();
  Function : Print a debug message.
  Returns  : none
  Args     : named arguments:
           : -errorlevel => number compared to $self->opts->{debug}
           : -msg        => string message
           :
=cut

###########################################################################
sub debug_msg {
    my $self   = shift;
    my $errlev = shift;
    my $msg    = shift;
    if ($self->opts->{debug} >= $errlev) { print "$msg\n"; }
}

###########################################################################

=head2 get_error
 
  Title    : get_error
  Usage    : $self->get_error();
  Function : Print a detailed error message
  Returns  : none
  Args     : -error        => response error
           :
=cut

###########################################################################
sub get_error {
    my $self  = shift;
    my $error = shift;
    my $keep = shift;

    if (!$self->{_error_buf}) {
        $self->{_error_buf} = [];
    }
    my $xPath        = XML::XPath->new($error);
    my $nodeset      = $xPath->find('/Error');
    my $node         = $nodeset->get_node(1);
    my $errorCode    = $node->findvalue('@minorErrorCode')->string_value;
    my $errorMessage = $node->findvalue('@message')->string_value;
    if ($keep) {
        my $msg = 'Failed: ' . $errorCode . ' with message \'' . $errorMessage . '\'';
        push @{$self->{_error_buf}}, $msg;
    }
    else {
        $self->debug_msg(0, 'Failed: ' . $errorCode . ' with message \'' . $errorMessage . '\'');
    }
    return;
}

###########################################################################

=head2 get_error_by_code
 
  Title    : get_error_by_code
  Usage    : $self->get_error_by_code();
  Function : Print a detailed error message
  Returns  : none
  Args     : -error_code        => response error code
           : -error_message     => response error message
           :
=cut

###########################################################################
sub get_error_by_code {
    my $self          = shift;
    my $error_code    = shift;
    my $error_message = shift;

    my $errorDesc = EMPTY;

    #using if statement, switch module didn't work.
    if    ($error_code eq '200') { $errorDesc = 'The request is valid and was completed. The response includes a document body.'; }
    elsif ($error_code eq '201') { $errorDesc = 'The request is valid. The requested object was created and can be found at the URL specified in the Location header.'; }
    elsif ($error_code eq '202') { $errorDesc = 'The request is valid and a task was created to handle it. This response is usually accompanied by a task URL.'; }
    elsif ($error_code eq '204') { $errorDesc = 'The request is valid and was completed. The response does not include a body.'; }
    elsif ($error_code eq '303') { $errorDesc = 'The response to the request can be found at the URL specified in the Location header.'; }
    elsif ($error_code eq '400') { $errorDesc = 'The request body is malformed, incomplete, or otherwise invalid.'; }
    elsif ($error_code eq '401') { $errorDesc = 'An authorization header was expected but not found.'; }
    elsif ($error_code eq '403') { $errorDesc = 'The requesting user does not have adequate privileges to access one or more objects specified in the request.'; }
    elsif ($error_code eq '404') { $errorDesc = 'One or more objects specified in the request could not be found in the specified container.'; }
    elsif ($error_code eq '405') { $errorDesc = 'The HTTP method specified in the request is not supported for this object.'; }
    elsif ($error_code eq '500') { $errorDesc = 'The request was received but could not be completed due to an internal error at the server.'; }
    elsif ($error_code eq '501') { $errorDesc = 'The request is not implemented by the server.'; }
    elsif ($error_code eq '503') { $errorDesc = 'One or more services needed to complete the request are not available on the server.'; }
    else                         { return; }

    $self->debug_msg(0, 'Error: ' . $error_code . ' ' . $error_message . ' with message \'' . $errorDesc . '\'');
    return;
}

###########################################################################

=head2 issue_request
 
  Title    : issue_request
  Usage    : $self->issue_request();
  Function : issue the HTTP request, do special processing, and return result
  Returns  : xml - response content
  Args     : -postType          => HTTP request method
           : -urlText           => url to send the request
           : -content_type      => Type of the content body
           : -content           => Content body
           :
=cut

###########################################################################
sub issue_request {
    my ($self, @params) = @_;


    my $response;
    my $tries = 1;
    if ($self->{retry_on_failure}) {
        $tries = $self->opts->{retry_attempts_count} || 10;
        $self->debug_msg(1, "Retry on failure enabled. Total tries: $tries");
    }
    my $cnt = 1;
    while ($tries--) {
        $response = $self->__issue_request_internal(@params);
        if (!$response && $self->{retry_on_failure}) {
            $self->debug_msg(1, "Try: #" . $cnt++ . " was unsuccessful.");
        }
        if ($response) {
            $self->debug_msg(1, "Success: " . $response) if $self->{retry_on_failure};
            $self->opts->{exitcode} = 0;
            last;
        }
        sleep $self->opts->{retry_interval};
    }
    if ($self->{retry_on_failure} && !$response) {
        for my $error (@{$self->{_error_buf}}) {
            $self->debug_msg(0, $error);
        }
    }
    return $response
}

sub __issue_request_internal {
    my $self        = shift;
    my $postType    = shift;
    my $urlText     = shift;
    my $contentType = shift;
    my $content     = shift;

    my $url;
    my $req;
    my $response;

    my $keep = $self->{retry_on_failure} ? 1 : 0;
    my %methods_allowed = map {$_ => 1} qw/GET POST PUT DELETE/;
    $methods_allowed{$postType} or $postType = 'GET';

    if ($urlText eq EMPTY) {
        $self->debug_msg(0, "Error: blank URL in issue_request.");
        $self->opts->{exitcode} = ERROR;
        return EMPTY;
    }

    $url = URI->new($urlText);
    $req = HTTP::Request->new($postType => $url);
    $req->authorization_basic($self->opts->{vclouddirector_user} . '@' . $self->opts->{vclouddirector_conf_org}, $self->opts->{vclouddirector_pass});

    if ($contentType ne EMPTY) {
        $req->content_type($contentType);
    }
    if ($content ne EMPTY) {
        $req->content($content);
    }

    $req->header('x-vcloud-authorization' => $::authHeader);
    $req->header('Accept', 'application/*+xml;version=' . $self->opts->{api_version}); 

    $self->debug_msg(6, "\nHTTP Request:" . $req->as_string);
    $response = $::browser->request($req);
    $self->debug_msg(6, "\nHTTP Response:" . $response->content);

    if ($response->is_error) {
        $self->debug_msg(0, $response->status_line);
        $self->get_error($response->content, $keep);
        $self->opts->{exitcode} = ERROR;
        return (EMPTY);
    }
    my $xml = $response->content;

    # HACK to work around tags comming back with name space vcloud: prepended
    # sometimes (randomly it seems)
    if ($xml =~ /vcloud:/) {
       # print "fixing XML vcloud: tags\n";
        $xml =~ s/vcloud://g;
    }

    return $xml;
}


=head2 getVmidReference

    Title       : issue_request
    Usage       : $self->getVmidReference
    Function    : Extracts vm-id href from vApp
    Returns     : VM-href
    Args        : vAppXML - vapp xml, from https://.../vApp/vapp-...
    
=cut

sub getVmidReference {
    my ($self, $vAppXML) = @_;
 
    croak "Missing vapp XML" unless $vAppXML;
    
    my @result;
    my $xPath = XML::XPath->new($vAppXML);
    my $nodeset = $xPath->find('//Children/Vm');
    
    for my $node ($nodeset->get_nodelist) {
        push @result, $node->getAttribute("href");
    }

    for my $vmData (@result) {
        $self->debug_msg(5, "VMID href found: " . $vmData);
    }

    $self->debug_msg(5, "Scalar of Result is : " . scalar(@result));
    return @result;
}

=head2 getVmData

    Title       : issue_request
    Usage       : $self->getVmData
    Function    : Get vm-data by vm-href
    Returns     : Vm xml
    Args        : vm href https://.../vApp/vm-...
    
=cut

sub getVmData {
    my ($self, $vmHref) = @_;

    croak "Missing vmid href" unless $vmHref;
    my $response = $self->issue_request(GET =>  $vmHref, EMPTY, EMPTY);
    return $response;
}


=head2 updateVm

    Title       : updateVm
    Usage       : $self->updateVm
    Function    : Updates vm data
    Returns     : 
    Args        : vm-id href, hash of parameters(vapp_name=> '...', vapp_hostname=> '...')
    
=cut

sub updateVm {
    my ($self, $vmid_href, %params) = @_;

    my ($hostname, $vapp_name);

    if ($params{vapp_name}) {
        $vapp_name = $params{vapp_name};
    }
    if ($params{vapp_hostname}) {
        $hostname = $params{vapp_hostname};
    }

    if (!$vapp_name && !$hostname) {
        croak "Missing parameters";
    }

    my $href = $vmid_href . '/guestCustomizationSection';
    my $data = $self->issue_request("GET", $href, EMPTY, EMPTY);

    $self->debug_msg(6, "DATA: $data\nHOST: $hostname\nNAME: $vapp_name\n");

    my $xml = $self->updateXML($data, $hostname, $vapp_name);

    my $task = $self->issue_request(
        "PUT",
        $href,
        'application/vnd.vmware.vcloud.guestCustomizationSection+xml',
        $xml
    );
    $self->debug_msg(6, "Hostname change, will wait for task: " . Dumper $task);
    $self->wait_task_by_xml($task);
    $self->debug_msg(6, "Params: " . Dumper \%params);
    # if vm_name is submitted, will update vm
    if ($params{vm_name}) {
        $self->debug_msg(6, "Updating VM name to $params{vm_name}");
        my $vm_content = $self->getVmData($vmid_href);
        my $object = XMLin_safe($vm_content);
        my $vm_name = $object->{name};
        $vm_content =~ s/$vm_name/$params{vm_name}/;
        $task = $self->issue_request(
            PUT => $vmid_href,
            'application/vnd.vmware.vcloud.vm+xml',
            $vm_content
        );
        $self->debug_msg(6, "Updating VM name, will wait for tasl: " . Dumper $task);
        $self->wait_task_by_xml($task);
    }
    $self->wait_for_all_tasks_of_vapp($self->{vapp_href});
}


=head2 updateXML

    Title       : updateXML
    Usage       : $self->updateXml
    Function    : Updates guestCustomizationSection XML with specified parameters
    Returns     : updated XML
    Args        : $xml, hostname, vmname
    
=cut

sub updateXML {
    my ($self, $xml, $hostname, $vmname) = @_;

    my $regexp;
    if ($vmname) {
        $regexp = "(<vssd:VirtualSystemIdentifier>)(.*?)(</vssd:VirtualSystemIdentifier>)";
        $xml =~ s|$regexp|${1}${vmname}${3}|ms;

    }
    if ($hostname) {
        $regexp = "(<ComputerName>)(.*?)(</ComputerName>)";
        $xml =~ s|$regexp|${1}${hostname}${3}|ms;
    }

    $xml =~ s|<AdminPassword>.*?</AdminPassword>||ms;
    return $xml;
}


=head2 wait_task_by_xml

    Title       : wait_task_by_xml
    Usage       : $self->wait_task_by_xml
    Function    : Wrapper around wait_task. This function passes task href to wait_task.
    Returns     : Task XML
    Args        : $xml
    
=cut

sub wait_task_by_xml {
    my ($self, $xml) = @_;

    unless ($xml) {
        croak "Missing xml";
    }

    $xml = XMLin($xml);
    my $href = $xml->{href};

    unless ($href) {
        print "Can't find task href in vCloudDirector response.\n";
        return 0;
    }

    return $self->wait_task($href);
}


=head2 wait_for_all_tasks_of_vapp

    Title       : wait_for_all_tasks_of_vapp
    Usage       : $self->wait_for_all_tasks_of_vapp
    Function    : This function waits for completion of all tasks of desired vApp.
    Returns     : Boolean value
    Args        : $vAppHref
    
=cut

sub wait_for_all_tasks_of_vapp {
    my ($self, $vAppHref) = @_;

    croak "No vAppHref is present\n" unless $vAppHref;
    my $retval = 1;

    my $counter = 0;
    # we going to check
    while (1) {
        # xml - vapp xml
        my $xml = $self->issue_request(
            GET => $vAppHref,
            '',
            ''
        );

        # no xml - we should return
        unless ($xml) {
            $retval = 0;
            last;
        }

        my $obj = XMLin_safe($xml);
        # there is malformed xml
        unless ($obj) {
            $retval = 0;
            last;
        }

        # Tasks are completed or not present
        if (!$obj->{Tasks}) {
            $retval = 1;
            $self->debug_msg(6, "All tasks are done\n");
            last;
        }
        else {
            $self->debug_msg(6, "Waiting for tasks completion\n");
        }

        $counter++;
        if ($counter >= 30) {
            $self->debug_msg(6, "timeout exceeded\n");
            $retval = 0;
            last;
        }
        sleep WAIT_SLEEP_TIME;
    }

    return $retval;
}


=head2 XMLin_safe

    Title       : XMLin_safe
    Usage       : XMLin_safe
    Function    : Wrapper around XMLin with eval integrated
    Returns     : parsed object or undef
    Args        : $xml
    
=cut

sub XMLin_safe {
    my ($xml) = @_;

    return undef unless $xml;

    my $object = undef;

    eval {
        $object = XMLin($xml);
        1;
    } or do {
        print "Malformed XML\n";
    };

    return $object;
}

sub extractDeployHref {
    my ($self, $nodeset) = @_;

    my $deployHref = undef;
    foreach my $node ($nodeset->get_nodelist) {
        if ($node->findvalue('@rel')->string_value eq 'deploy') {
            $deployHref = $node->findvalue('@href')->string_value;
            last;
        }
    }
    return $deployHref;
}

1;
