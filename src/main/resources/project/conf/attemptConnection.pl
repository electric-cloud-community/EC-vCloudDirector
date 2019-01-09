##########################
# attemptConnection.pl
##########################


use ElectricCommander;
use ElectricCommander::PropDB;
use LWP::UserAgent;
use MIME::Base64;

use Carp qw( carp croak );

use constant {
               SUCCESS => 0,
               ERROR   => 1,
             };

## get an EC object
my $ec = new ElectricCommander();
$ec->abortOnError(0);

my $credName = '$[/myJob/config]';

my $xpath  = $ec->getFullCredential("credential");
my $errors = $ec->checkAllErrors($xpath);
my $user   = $xpath->findvalue("//userName");
my $pass   = $xpath->findvalue("//password");

my $projName = '$[/myProject/projectName]';
print "Attempting connection with server\n";
print "-- Authenticating with server --\n";

#-----------------------------
# Create new LWP browser
#-----------------------------
my $browser = LWP::UserAgent->new(agent => 'perl LWP', cookie_jar => {});

my $vclouddirector_url = '$[vclouddirector_url]';
my $vclouddirector_org = '$[vclouddirector_conf_org]';


#set login url
my $auth_url = '$[/myProject/vclouddirector_cfgs/$[/myJob/config]/api_login]';
my $api_version = '$[/myProject/vclouddirector_cfgs/$[/myJob/config]/api_version]';

#-----------------------------
# Authentication Request
#-----------------------------
print 'Authenticating with \'' . $auth_url . qq{'\n};
print 'API version: ' . $api_version . "\n";
my $url = URI->new($auth_url);
#-----------------------------
# Post to url, included authentication string to get session token
#-----------------------------
my $req = HTTP::Request->new(POST => $auth_url);

#-----------------------------
# Set authentication string, format is username@hostingacct:password
#-----------------------------
$req->authorization_basic($user . '@' . $vclouddirector_org, $pass);
$req->header('Accept', 'application/*+xml;version=' . $api_version);

print "Request:" . $req->as_string;
my $response = $browser->request($req);
print "Response:" . $response->as_string;

print q{    Authentication status: } . $response->status_line;

#-----------------------------
# Check if successful login
#-----------------------------
if ($response->is_error) {
    my $errMsg = "\nTest connection failed.\n";
    $ec->setProperty("/myJob/configError", $errMsg);
    print $errMsg;

    $ec->deleteProperty("/projects/$projName/vclouddirector_cfgs/$credName");
    $ec->deleteCredential($projName, $credName);

    print $response->status_line;
    print $response->code;
    exit ERROR;

    exit ERROR;
}

exit SUCCESS;


