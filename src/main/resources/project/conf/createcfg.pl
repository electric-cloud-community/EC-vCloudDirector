#########################
## createcfg.pl
#########################

use ElectricCommander;
use ElectricCommander::PropDB;
use XML::XPath;
use Data::Dumper;

$ENV{'PERL_LWP_SSL_VERIFY_HOSTNAME'} = 0;

use constant {
               SUCCESS => 0,
               ERROR   => 1,
             };

my $opts;

my $PLUGIN_NAME = "EC-vCloudDirector";

if (!defined $PLUGIN_NAME) {
    print "PLUGIN_NAME must be defined\n";
    exit ERROR;
}

## get an EC object
my $ec = new ElectricCommander();
$ec->abortOnError(0);

## load option list from procedure parameters
my $x       = $ec->getJobDetails($ENV{COMMANDER_JOBID});
my $nodeset = $x->find("//actualParameter");
foreach my $node ($nodeset->get_nodelist) {
    my $parm = $node->findvalue("actualParameterName");
    my $val  = $node->findvalue("value");
    $opts->{$parm} = "$val";
}

if (!defined $opts->{config} || "$opts->{config}" eq "") {
    print "config parameter must exist and be non-blank\n";
    exit ERROR;
}

# check to see if a config with this name already exists before we do anything else
my $xpath    = $ec->getProperty("/myProject/vclouddirector_cfgs/$opts->{config}");
my $property = $xpath->findvalue("//response/property/propertyName");

if (defined $property && "$property" ne "") {
    my $errMsg = "A configuration named '$opts->{config}' already exists.";
    $ec->setProperty("/myJob/configError", $errMsg);
    print $errMsg;
    exit ERROR;
}

#-----------------------------
# Show Login URL and List Supported API Versions
#-----------------------------

my $browser = LWP::UserAgent->new(
    agent           => 'perl LWP',
    cookie_jar      => {},
    verify_hostname => 0
);
my $auth_url;
my $url;
my $errMsg;
my $xml;

#remove last / if exist
if ($opts->{vclouddirector_url} =~ /\/$/) {
    $opts->{vclouddirector_url} =~ s/\/$//;
}

my $vclouddirector_url = $opts->{vclouddirector_url};

# Why it was done?
#change https for http to get api version
# if ($vclouddirector_url =~ /^https:/) {
#     $vclouddirector_url =~ s/https/http/;
# }

# GET http://hostname/api/versions
$auth_url = $vclouddirector_url . q{/api/versions};
$url      = URI->new($auth_url);
$req      = HTTP::Request->new(GET => $auth_url);

print "Request API:" . $req->as_string;
$response = $browser->request($req);

#-----------------------------
# Check successful request
#-----------------------------
if ($response->is_error) {
    $errMsg = "\nTest connection failed.\n";
    print $errMsg;

    print $response->status_line;
    print $response->code;
    exit ERROR;
}

$xml = $response->content;

# HACK to work around tags comming back with name space vcloud: prepended
# sometimes (randomly it seems)
if ($xml =~ /vcloud:/) {
    print "fixing XML vcloud: tags\n";
    $xml =~ s/vcloud://g;
}

#Get server API versions
my @versions;
my @version_url;
my $xPath   = XML::XPath->new($xml);
my $nodeset = $xPath->find('//VersionInfo');
foreach my $node ($nodeset->get_nodelist) {
     # print $node->findvalue('Version')->string_value . "\n";
     # print $node->findvalue('LoginUrl')->string_value . "\n";
    push @versions,    $node->findvalue('Version')->string_value;
    push @version_url, $node->findvalue('LoginUrl')->string_value;
}

#List of supported API versions
my $supp_versions = '1.0,1.5,5.5';
my $versions_size = scalar @versions;
@versions = sort {$a <=> $b} @versions;

my $cfg = ElectricCommander::PropDB->new($ec, "/myProject/vclouddirector_cfgs");

#Check if supported
my $version_picked = '0';


# print $versions_size . "\n";
if ($versions_size ne 0) {
    for ($i = $versions_size; $i >= 0; $i--) {
        print $version[$i];
        if ($supp_versions =~ m/$versions[$i-1]/) {
            print "Version " . $versions[$i-1] . " supported\n";
            $cfg->setCol("$opts->{config}", "api_version", $versions[$i-1]);
            $cfg->setCol("$opts->{config}", "api_login",   $version_url[$i-1]);
            $version_picked = '1';
            last;
        }
    }
}

if ($version_picked eq '0') {
    $errMsg = "The API versions in server '" . $opts->{vclouddirector_url} . "' are not supported by this plugin.\n"; 
    $ec->setProperty("/myJob/configError", $errMsg);
    print $errMsg;
    exit ERROR;
}

# add all the options as properties
foreach my $key (keys %{$opts}) {
    if ("$key" eq "config") {
        next;
    }
    $cfg->setCol("$opts->{config}", "$key", "$opts->{$key}");
}
exit SUCCESS;

