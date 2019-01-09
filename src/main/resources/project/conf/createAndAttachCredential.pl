##########################
# createAndAttachCredential.pl
##########################

use ElectricCommander;

use constant {
    SUCCESS => 0,
    ERROR   => 1,
};

my $ec = new ElectricCommander();
$ec->abortOnError(0);

my $credName = '$[/myJob/config]';
my $xpath    = $ec->getFullCredential("credential");
my $userName = $xpath->findvalue("//userName");
my $password = $xpath->findvalue("//password");

# Create credential
my $projName = "@PLUGIN_KEY@-@PLUGIN_VERSION@";

$ec->deleteCredential( $projName, $credName );
$xpath = $ec->createCredential( $projName, $credName, $userName, $password );
my $errors = $ec->checkAllErrors($xpath);

# Give config the credential's real name
my $configPath = "/projects/$projName/vclouddirector_cfgs/$credName";
$xpath = $ec->setProperty( $configPath . "/credential", $credName );
$errors .= $ec->checkAllErrors($xpath);

# Give job launcher full permissions on the credential
my $user = '$[/myJob/launchedByUser]';
$xpath = $ec->createAclEntry(
    "user", $user,
    {
        projectName                => $projName,
        credentialName             => $credName,
        readPrivilege              => allow,
        modifyPrivilege            => allow,
        executePrivilege           => allow,
        changePermissionsPrivilege => allow
    }
);
$errors .= $ec->checkAllErrors($xpath);

# Attach credential to steps that will need it
$xpath = $ec->attachCredential(
    $projName,
    $credName,
    {
        procedureName => "Provision",
        stepName      => "Provision"
    }
);
$errors .= $ec->checkAllErrors($xpath);

$xpath = $ec->attachCredential(
    $projName,
    $credName,
    {
        procedureName => "Clone",
        stepName      => "Clone"
    }
);
$errors .= $ec->checkAllErrors($xpath);

$xpath = $ec->attachCredential(
    $projName,
    $credName,
    {
        procedureName => "Cleanup",
        stepName      => "Cleanup"
    }
);
$errors .= $ec->checkAllErrors($xpath);

$xpath = $ec->attachCredential(
    $projName,
    $credName,
    {
        procedureName => "CreateConfiguration",
        stepName      => "CreateConfiguration"
    }
);
$errors .= $ec->checkAllErrors($xpath);

$xpath = $ec->attachCredential(
    $projName,
    $credName,
    {
        procedureName => "Capture",
        stepName      => "Capture"
    }
);
$errors .= $ec->checkAllErrors($xpath);

$xpath = $ec->attachCredential(
    $projName,
    $credName,
    {
        procedureName => "GetvApp",
        stepName      => "GetvApp"
    }
);
$errors .= $ec->checkAllErrors($xpath);

if ( "$errors" ne "" ) {

    # Cleanup the partially created configuration we just created
    $ec->deleteProperty($configPath);
    $ec->deleteCredential( $projName, $credName );
    my $errMsg = "Error creating configuration credential: " . $errors;
    $ec->setProperty( "/myJob/configError", $errMsg );
    print $errMsg;
    exit ERROR;
}
