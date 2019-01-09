use ElectricCommander;
use File::Basename;
use ElectricCommander::PropDB;
use ElectricCommander::PropMod;
use Encode;
use utf8;

$| = 1;

use constant {
    SUCCESS => 0,
    ERROR   => 1,
};

# Create ElectricCommander instance
my $ec = new ElectricCommander();
$ec->abortOnError(0);

my $pluginKey  = 'EC-vCloudDirector';
my $xpath      = $ec->getPlugin($pluginKey);
my $pluginName = $xpath->findvalue('//pluginVersion')->value;
print "Using plugin $pluginKey version $pluginName\n";
$opts->{pluginVer} = $pluginName;
my $retry_on_failure = 0;

if ( defined( $opts->{connection_config} ) && $opts->{connection_config} ne "" ) {
    my $cfgName = $opts->{connection_config};
    print "Loading config $cfgName\n";

    my $proj = '$[/myProject/projectName]';
    my $cfg  = new ElectricCommander::PropDB( $ec,
        "/projects/$proj/vclouddirector_cfgs" );

    my %vals = $cfg->getRow($cfgName);

    # Check if configuration exists
    unless ( keys(%vals) ) {
        print "Configuration [$cfgName] does not exist\n";
        exit ERROR;
    }

    # Add all options from configuration
    foreach my $c ( keys %vals ) {
        print "Adding config $c = $vals{$c}\n";
        $opts->{$c} = $vals{$c};
    }
    if ($opts->{retry_on_failure}) {
        $retry_on_failure = 1;
    }
    if ((defined $opts->{retry_interval} && $opts->{retry_interval} !~ m/^\d+$/s) || $opts->{retry_interval} eq '0') {
        print "retry_interval should be a positive integer";
        exit 1;
    }
    if ((defined $opts->{retry_attempts_count} && $opts->{retry_attempts_count} !~ m/^\d+$/s) || $opts->{retry_attempts_count} eq '0') {
        print "retry_attempts_count should be a positive integer";
        exit 1;
    }

    if ($opts->{retry_on_failure}) {
        $opts->{retry_interval} = 5 if !$opts->{retry_interval};
        $opts->{retry_attempts_count} = 10 if !$opts->{retry_attempts_count};
    }

    # Check that credential item exists
    if ( !defined $opts->{credential} || $opts->{credential} eq "" ) {
        print
"Configuration [$cfgName] does not contain an vCloudDirector credential\n";
        exit ERROR;
    }

    # Get user/password out of credential named in $opts->{credential}
    my $xpath = $ec->getFullCredential("$opts->{credential}");
    $opts->{vclouddirector_user} = $xpath->findvalue("//userName");
    $opts->{vclouddirector_pass} = $xpath->findvalue("//password");

    # Check for required items
    if ( !defined $opts->{vclouddirector_url} || $opts->{vclouddirector_url} eq "" ) {
        print "Configuration [$cfgName] does not contain an vCloudDirector server url\n";
        exit ERROR;
    }
}
# print "Retry on failure: $retry_on_failure\n";
$opts->{JobStepId} =  '$[/myJobStep/jobStepId]';

# Load the actual code into this process
if (
    !ElectricCommander::PropMod::loadPerlCodeFromProperty(
        $ec, '/myProject/vclouddirector_driver/vCloudDirector'
    )
  )
{
    print 'Could not load vCloudDirector.pm\n';
    exit ERROR;
}

# Make an instance of the object, passing in options as a hash
my $gt = new vCloudDirector($ec, $opts, $retry_on_failure);
