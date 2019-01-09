##########################
# step.grow.pl
##########################
use ElectricCommander;
use ElectricCommander::PropDB;

$::ec = new ElectricCommander();
$::ec->abortOnError(0);

$| = 1;

my $number          = '$[number]';
my $poolName        = '$[poolName]';
my $vcloud_config   = '$[connection_config]';
my $vcloud_org      = '$[vcloud_organization]';
my $vcloud_catalog  = '$[vcloud_catalog]';
my $vcloud_template = '$[vcloud_template]';
my $vcloud_vdc      = '$[vcloud_virtual_datacenter]';
my $vcloud_vapp     = '$[vcloud_vappname]';
my $vcloud_network  = '$[vcloud_network]';
my $vcloud_par_net  = '$[vcloud_parent_network]';
my $vcloud_fenced   = '$[vcloud_fenced_mode]';
my $vcloud_tag      = '$[tag]';
my $vcloud_results  = '$[results]';

my @deparray = split(/\|/, $deplist);

sub main {
    print "vCloudDirector Grow:\n";

    # Validate inputs
    $number          =~ s/[^0-9]//gixms;
    $poolName        =~ s/[^A-Za-z0-9_-\s].*//gixms;
    $vcloud_config   =~ s/[^A-Za-z0-9_-\s]//gixms;
    $vcloud_org      =~ s/[^A-Za-z0-9_-\s]//gixms;
    $vcloud_catalog  =~ s/[^A-Za-z0-9_-\s]//gixms;
    $vcloud_template =~ s/[^A-Za-z0-9_-\s]//gixms;
    $vcloud_vdc      =~ s/[^A-Za-z0-9_-\s]//gixms;
    $vcloud_vapp     =~ s/[^A-Za-z0-9_-\s]//gixms;
    $vcloud_network  =~ s/[^A-Za-z0-9_-\s]//gixms;
    $vcloud_par_net  =~ s/[^A-Za-z0-9_-\s]//gixms;
    $vcloud_fenced   =~ s/[^A-Za-z0-9_-\s]//gixms;
    $vcloud_tag      =~ s/[^A-Za-z0-9_-\s]//gixms;
    $vcloud_results  =~ s/[^A-Za-z0-9_\-\/\s]//gixms;

    my $xmlout = "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n";
    addXML(\$xmlout, "<GrowResponse>");

    ### CREATE VAPPS ###
    my $count       = $number;
    my $vapp_number = '1';
    for (1 .. $number) {
        $vapp_number = $_;

        print("Running vCloudDirector Provision\n");
        my $proj = '$[/myProject/projectName]';
        my $proc = "Provision";
        my $xPath = $::ec->runProcedure(
                                        "$proj",
                                        {
                                           procedureName   => "$proc",
                                           pollInterval    => 1,
                                           timeout         => 3600,
                                           actualParameter => [{ actualParameterName => "connection_config", value => "$vcloud_config" }, { actualParameterName => "vcloud_organization", value => "$vcloud_org" }, { actualParameterName => "vcloud_catalog", value => "$vcloud_catalog" }, { actualParameterName => "vcloud_template", value => "$vcloud_template" }, { actualParameterName => "vcloud_virtual_datacenter", value => "$vcloud_vdc" }, { actualParameterName => "vcloud_vappname", value => "$vcloud_vapp-$[jobStepId]-$vapp_number" }, { actualParameterName => "vcloud_network", value => "$vcloud_network" }, { actualParameterName => "vcloud_parent_network", value => "$vcloud_par_net" }, { actualParameterName => "vcloud_fenced_mode", value => "$vcloud_fenced" }, { actualParameterName => "tag", value => "$vcloud_tag" }, { actualParameterName => "results", value => "/myJob/vCloudDirector/deployed/" }, { actualParameterName => "pools", value => "$poolName" },],
                                        }
                                       );
        if ($xPath) {
            my $code = $xPath->findvalue('//code');
            if ($code ne "") {
                my $mesg = $xPath->findvalue('//message');
                print "Run procedure returned code is '$code'\n$mesg\n";
            }
        }
        my $outcome = $xPath->findvalue('//outcome')->string_value;
        if ("$outcome" ne "success") {
            print "vCloudDirector Provision job failed.\n";
            next;

            #exit 1;
        }
        my $jobId = $xPath->findvalue('//jobId')->string_value;
        if (!$jobId) {

            #exit 1;
            next;
        }
        print "Provision succeded: vApp name $vcloud_vapp-$[jobStepId]-$vapp_number\n";
        
        my $depobj = new ElectricCommander::PropDB($::ec, "");
        my $vmList = $depobj->getProp("/jobs/$jobId/vCloudDirector/deployed/$vcloud_tag/VMList");
        print "VM list=$vmList\n";
        my @vms = split(/;/, $vmList);
        my $createdList = ();

        foreach my $vm (@vms) {
            addXML(\$xmlout, "  <Deployment>");
            addXML(\$xmlout, "      <handle>$vm</handle>");
            addXML(\$xmlout, "      <hostname>" . $depobj->getProp("/jobs/$jobId/vCloudDirector/deployed/$vcloud_tag/$vm/IpAddress") . "</hostname>");
            addXML(\$xmlout, "      <href>" . $depobj->getProp("/jobs/$jobId/vCloudDirector/deployed/$vcloud_tag/$vm/href") . "</href>");
            addXML(\$xmlout, "      <resource>" . $depobj->getProp("/jobs/$jobId/vCloudDirector/deployed/$vcloud_tag/$vm/Resource") . "</resource>");
            addXML(\$xmlout, "      <vApp>" . $depobj->getProp("/jobs/$jobId/vCloudDirector/deployed/$vcloud_tag/$vm/vApp") . "</vApp>");
            addXML(\$xmlout, "      <VM>" . $depobj->getProp("/jobs/$jobId/vCloudDirector/deployed/$vcloud_tag/$vm/Name") . "</VM>");
            addXML(\$xmlout, "      <Org>" . $depobj->getProp("/jobs/$jobId/vCloudDirector/deployed/$vcloud_tag/$vm/Org") . "</Org>");
            addXML(\$xmlout, "      <VDC>" . $depobj->getProp("/jobs/$jobId/vCloudDirector/deployed/$vcloud_tag/$vm/VDC") . "</VDC>");
            addXML(\$xmlout, "      <results>/jobs/$jobId/vCloudDirector/deployed</results>");
            addXML(\$xmlout, "      <tag>$vcloud_tag</tag>");
            addXML(\$xmlout, "  </Deployment>");
        }

    }
    addXML(\$xmlout, "</GrowResponse>");

    my $prop = "/myJob/CloudManager/grow";
    print "Registering results for $vmList in $prop\n";
    $::ec->setProperty("$prop", $xmlout);
}

sub addXML {
    my ($xml, $text) = @_;
    ## TODO encode
    ## TODO autoindent
    $$xml .= $text;
    $$xml .= "\n";
}

main();
