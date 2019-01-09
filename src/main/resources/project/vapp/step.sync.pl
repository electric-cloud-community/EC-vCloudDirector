##########################
# step.sync.pl
##########################
use ElectricCommander;
use ElectricCommander::PropDB;
use strict;

$::ec = new ElectricCommander();
$::ec->abortOnError(0);
$::pdb = new ElectricCommander::PropDB($::ec);

$| = 1;

my $vcloud_config   = '$[connection_config]';
my $deployments = '$[deployments]';

sub main {
    print "vClouDirector Sync:\n";

    # Validate inputs
    $vcloud_config =~ s/[^A-Za-z0-9_-]//gixms;

    # unpack request
    my $xPath = XML::XPath->new(xml => $deployments);
    my $nodeset = $xPath->find('//Deployment');

    my $instanceList = "";

    # put request in perl hash
    my $deplist;
    foreach my $node ($nodeset->get_nodelist) {

        # for each deployment
        my $i     = $xPath->findvalue('handle',    $node)->string_value;
        my $s     = $xPath->findvalue('state',     $node)->string_value;    # alive
        my $vapp         = $xPath->findvalue('vApp',     $node)->string_value;
        my $vm           = $xPath->findvalue('VM',       $node)->string_value;
        my $org          = $xPath->findvalue('Org',      $node)->string_value;
        my $vdc          = $xPath->findvalue('VDC',      $node)->string_value;
        my $resultspath  = $xPath->findvalue('results',  $node)->string_value; 
        my $tag  = $xPath->findvalue('tag',  $node)->string_value;
        print "Input: $i state=$s\n";
        $deplist->{$i}{state}  = "alive";                                   # we only get alive items in list
        $deplist->{$i}{result} = "alive";

        $deplist->{$i}{vapp}        = $vapp;
        $deplist->{$i}{vm}          = $vm;
        $deplist->{$i}{org}         = $org;
        $deplist->{$i}{vdc}         = $vdc;
        $deplist->{$i}{resultspath} = $resultspath;
        $deplist->{$i}{tag} = $tag;
        $instanceList .= "$i\;";
    }

    checkIfAlive($instanceList, $deplist);

    my $xmlout = "";
    addXML(\$xmlout, "<SyncResponse>");
    foreach my $handle (keys %{$deplist}) {
        my $result = $deplist->{$handle}{result};
        my $state  = $deplist->{$handle}{state};

        addXML(\$xmlout, "<Deployment>");
        addXML(\$xmlout, "  <handle>$handle</handle>");
        addXML(\$xmlout, "  <state>$state</state>");
        addXML(\$xmlout, "  <result>$result</result>");
        addXML(\$xmlout, "</Deployment>");
    }
    addXML(\$xmlout, "</SyncResponse>");
    $::ec->setProperty("/myJob/CloudManager/sync", $xmlout);
    print "\n$xmlout\n";
    exit 0;
}

# checks status of instances
# if found to be stopped, it marks the deplist to pending
# otherwise (including errors running api) it assumes it is still running
sub checkIfAlive {
    my ($instances, $deplist) = @_;

    foreach my $handle (keys %{$deplist}) {

        ### get config state ###
        print("Running vClouDirector GetvApp \n");
        my $proj = '$[/myProject/projectName]';
        my $proc = "GetvApp";
        my $xPath = $::ec->runProcedure(
                                        "$proj",
                                        {
                                           procedureName   => "$proc",
                                           pollInterval    => 1,
                                           timeout         => 3600,
                                           actualParameter =>  [

                                                               { actualParameterName => "connection_config",         value => "$vcloud_config" },
                                                               { actualParameterName => "vcloud_organization",       value => "$deplist->{$handle}{org}" },
                                                               { actualParameterName => "vcloud_virtual_datacenter", value => "$deplist->{$handle}{vdc}" },
                                                               { actualParameterName => "vcloud_vappname",           value => "$deplist->{$handle}{vapp}" },
                                                               { actualParameterName => "tag",                       value => "$deplist->{$handle}{tag}" },
                                                               { actualParameterName => "results",                   value => "" },
                                  ],
                                        }
                                       );
        if ($xPath) {
            my $code = $xPath->findvalue('//code')->string_value;
            if ($code ne "") {
                my $mesg = $xPath->findvalue('//message')->string_value;
                print "Run procedure returned code is '$code'\n$mesg\n";
                return;
            }
        }
        my $outcome = $xPath->findvalue('//outcome')->string_value;
        my $jobid   = $xPath->findvalue('//jobId')->string_value;
        if (!$jobid) {

            # at this point we have to assume it is still running becaue we could not prove otherwise
            print "could not find jobid of Command job.\n";
            return;
        }
        my $response = $::pdb->getProp("/jobs/$jobid/vCloudDirector/deployed/$deplist->{$handle}{tag}/vApp");
        if ("$response" eq "") {
            my $command_error = $::pdb->getProp("/jobs/$jobid/vCloudDirector/deployed/$deplist->{$handle}{tag}/command_error");
            if ($command_error =~ m/.*not found./) {
                $::ec->setProperty("/jobs/$jobid/outcome","success");
                print("VM $deplist->{$handle}{vm} in vApp $deplist->{$handle}{vapp} stopped\n");
                $deplist->{$handle}{state}  = "pending";
                $deplist->{$handle}{result} = "success";
                $deplist->{$handle}{mesg}   = "VM was manually stopped or failed";
                next;
            }
            
            print "could not find results of vApp in /jobs/$jobid/vCloudDirector/deployed/$deplist->{$handle}{tag}/vApp\n";
            return;
        }
        my $respath = XML::XPath->new(xml => "$response");

        my $nodeset   = $respath->find('/VApp/Children/Vm');
        my $state = '';
        foreach my $node ($nodeset->get_nodelist) {

            if ($node->findvalue('@name')->string_value eq $deplist->{$handle}{vm}) {
                    my $name = $node->findvalue('@name')->string_value;
                    $state = $node->findvalue('@status')->string_value;
                    last;
            }
        }
        # deployment specific response

        #print "state $state\n";
        my $err = "success";
        my $msg = "";
        if ("$state" eq "4") {
            print("VM $deplist->{$handle}{vm} in vApp $deplist->{$handle}{vapp} still running\n");
            $deplist->{$handle}{state}  = "alive";
            $deplist->{$handle}{result} = "success";
            $deplist->{$handle}{mesg}   = "VM still running";
        }
        else {
            print("VM $deplist->{$handle}{vm} in vApp $deplist->{$handle}{vapp} stopped\n");
            $deplist->{$handle}{state}  = "pending";
            $deplist->{$handle}{result} = "success";
            $deplist->{$handle}{mesg}   = "VM was manually stopped or failed";
        }
    }
    return;
}

sub addXML {
    my ($xml, $text) = @_;
    ## TODO encode
    ## TODO autoindent
    $$xml .= $text;
    $$xml .= "\n";
}

main();
