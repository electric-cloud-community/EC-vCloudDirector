#-------------------------------------------------------------------------
# setup.pl
#
# Perform setup steps needed by the test suite.  Clears out state that
# might interfere with the tests and installs the plugin to test.
#-------------------------------------------------------------------------

use strict;
use ElectricCommander;

$| = 1;

# win/lin matches the chronic3 procedure platform property
$::gPlatform = "lin";
if ( $^O eq "MSWin32" ) {
    $::gPlatform = "win";
}

my $cmdrServer  = $::ARGV[0];
my $outtop      = $::ARGV[1];
my $plugin_ver  = $::ENV{PLUGIN_VERSION};
my $plugin_name = $::ENV{PLUGIN_NAME};
my $plugin_key  = $plugin_name;
$plugin_key =~ s/-[^-]+$//g;

$::ENV{PLUGIN_KEY} = $plugin_key;

my $N = new ElectricCommander($cmdrServer);
$N->abortOnError(0);

$::gJobId = $::ENV{COMMANDER_JOBID};

print "==========SYSTEM TEST SETUP============\n";
print "pluginArtifacts: $::ENV{PLUGINS_ARTIFACTS}\n";
print "outtop         : $outtop\n";
print "server         : $cmdrServer\n";
print "key            : $plugin_key\n";
print "ver            : $plugin_ver\n";
print "name           : $plugin_name\n";
print "platform       : $::gPlatform\n";
print "\n";

$N->login( 'admin', 'changeme' );

# Uninstall this plugin
print "Uninstalling $plugin_key\n";
$N->uninstallPlugin($plugin_name);
my $msg = $N->getError();
if ( $msg ne "" ) {
    print "Error uninstalling plugin $plugin_name.\n";
    print $msg;
    exit 1;
}

# Install this plugin
print "Installing $::ENV{PLUGINS_ARTIFACTS}/$plugin_key/$plugin_key.jar\n";
my $xpath =
  $N->installPlugin("$::ENV{PLUGINS_ARTIFACTS}/$plugin_key/$plugin_key.jar");
$msg = $N->getError();
if ( $msg ne "" ) {
    print "Error installing plugin $plugin_name.\n";
    print $msg;
    exit 1;
}
$plugin_name = $xpath->findvalue('//plugin/pluginName')->value;

# Promote this plugin
$N->promotePlugin("$plugin_name");
$msg = $N->getError();
if ( $msg ne "" ) {
    print "Error promoting plugin $plugin_name.\n";
    print $msg;
    exit 1;
}
print "Done with setup\n";
exit 0;
