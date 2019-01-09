# -*-Perl-*-

# fakeHTTPServer.pl
#
# Auxiliary helper for 'ntest'
# Used to serve files via http.
#
# Usage:
#    fakeHTTPServer [options]
#
# Sample
#    fakeHTTPServer --port 80 --data http_responses
#
# where data is a list of functions and their results .
#
# Copyright (c) 2011 Electric Cloud, Inc.
# All rights reserved

use strict;
use warnings;
use HTTP::Daemon;
use HTTP::Status;
use Getopt::Long;

# ------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------

use constant {
    SUCCESS => 0,
    ERROR   => 1,

    DEFAULT_DATA_FILE => 'http_responses',
    DEFAULT_PORT      => 80,
    DEFAULT_LOCALADDR => '127.0.0.1',
    DEFAULT_REUSEADDR => 1,
    DEFAULT_LISTEN    => 5,

    QUIT_CODE => '-1',
    NULL_CODE => '0',
};

# ------------------------------------------------------------------------
# Globals
# ------------------------------------------------------------------------

my $gLog       = '';                   # by default, send output to stderr
my $gIPAddress = DEFAULT_LOCALADDR;    # default IP address of server
my $gPort      = DEFAULT_PORT;         # default port to listen on
$::gDataFile = DEFAULT_DATA_FILE;      # data with fake soap responses
my %gResponses = ();    # request->response map, from cmd line args
$::gTimeout = 9999;     # very long timeout by default

my %gOptions = (

    # --log=<path>
    # If specified, send stderr to the specified file
    "log=s" => \$gLog,

    # --ip=<ip>
    # Run the server on the specified IP address (default: 127.0.0.1)
    "ip=s" => \$gIPAddress,

    # --port=<portnum>
    # Run the server on the specified port (default: 80)
    "port=i" => \$gPort,

    # --data=<datafile>
    # File that has fake data
    "data=s" => \$::gDataFile,

    # --timout-<seconds>
    # How many seconds to wait for data before shutting down
    "timeout=s" => \$::gTimeout,
);

$SIG{'INT'}    = \&exit_handler;
$SIG{'HUP'}    = \&exit_handler;
$SIG{__WARN__} = \&exit_handler;
$SIG{__DIE__}  = \&exit_handler;
END { $::daemon->close(); }

################################
# mesg - Write out message to log file
#
# Arguments:
#   None
#
# Returns:
#   mesg string
#
################################
sub mesg($) {
    my ($mesg) = @_;
    my $time = localtime();
    print( STDERR ( "[$time] " . $mesg . "\n" ) );
}

################################
# main
#
# Arguments:
#   None
#
# Returns:
#   None
#
################################
sub main {

    # Save original arguments so we can write to log after processing.
    my @originalArgs   = @ARGV;
    my $recordFileName = '';

    # Parse command line arguments into global variables.
    GetOptions(%gOptions);

    # If a logfile was specified, send STDERR there.
    if ( $gLog ne "" ) {
        open( STDERR, ">$gLog" );
    }

    loadValues();

    runServer(@originalArgs);
}

sub exit_handler {
    mesg("Caught Interrupt, Aborting");
    $::daemon->close();
    undef($::daemon);
    exit(1);
}

################################
# runServer - Run the HTTP server, wait for requests and send responses
#
# Arguments:
#   originalArgs array
#
# Returns:
#   None
#
################################
sub runServer {
    my (@originalArgs) = @_;

    eval {
        mesg('Starting http server');
        mesg( 'Args: ' . join( ' ', @originalArgs ) . '' );

        # Create new server.
        $::daemon = new HTTP::Daemon(
            LocalAddr => $gIPAddress,
            LocalPort => $gPort,
            ReuseAddr => DEFAULT_REUSEADDR,
            Listen    => DEFAULT_LISTEN,
            Timeout   => $::gTimeout,
        );
        mesg( 'URL: ' . $::daemon->url );

        # Get port and save it in port-ntest-http.log file
        my $port = "";
        $port = substr( $::daemon->sockport, 0 );
        open( PORTFILE, "> ../port-ntest-http.log" );
        print( PORTFILE "$port" );
        close(PORTFILE);

        # Write the URL to stdout so the caller can contact us
        $| = 1;

        # Wait for a connection
        my $code;
        my $responseContent;
        my $response;
        my $url = $::daemon->url;
        my $header = HTTP::Headers->new( Content_Type => 'text/xml;', );
        while ( my $connection = $::daemon->accept ) {

            # Process the next request
            while ( my $request = $connection->get_request ) {
                mesg('Request received');
                mesg( $request->uri );
                ( $code, $responseContent ) = getResponseFromAction($request);

                mesg( "code " . $code );

                $responseContent =~ s/https:\/\/vcloud-web\//$url/g;
                mesg( "responseContent " . $responseContent );

                if ( $code ne NULL_CODE ) {

                    # Create and send response response
                    $response = HTTP::Response->new( $code, '', $header,
                        $responseContent );
                    $connection->send_response($response);
                }

                # Shutdown the server
                if ( $code eq QUIT_CODE ) {
                    mesg('Shutting down server');
                    exit SUCCESS;
                }
            }
            $connection->close;
            undef($connection);
        }
    } or mesg('An error occured when starting or running the HTTP server');
}

################################
# getResponseFromAction - Get the code and response content from the specified Action
#
# Arguments:
#   requestContent - string
#
# Returns:
#   code            - string
#   responseContent - string
#
################################
sub getResponseFromAction {
    my ($request) = @_;
    my $action;
    my $uri    = $request->uri;
    my $method = $request->method;
    if($uri =~ m/api\/.*\d\/(.+)/)
    {
    if ( $method eq "DELETE" ) {
        $action = "del/$1";
    }
    else { $action = "$1"; }
}
else
    {
        $action = "api/versions";
    }
    
    if ($action) {
        mesg( 'Action: ' . $action );
        my $codeResponse = getResponseItem($action);
        return split( /\|/, $codeResponse );
    }
    else {
        mesg('No action specified in request');
        return;
    }
}

################################
# loadValues - Get values from file
#
# Arguments:
#   None
#
# Returns:
#   None
#
################################
sub loadValues() {

    # Open the file
    my @data = ();
    if ( !-f $::gDataFile ) {
        mesg("File $::gDataFile not found");
        return;
    }
    open( DAT, $::gDataFile );
    @data = <DAT>;
    close(DAT);

    # process each line
    foreach my $line (@data) {

        # skip blank and commented lines
        chomp($line);
        if ( substr( $line, 0, 1 ) eq "#" ) { next; }
        if ( length($line) == 0 ) { next; }
        my ( $key, $resp ) = split( /\|/, $line, 2 );

        # push on global hash
        push( @{ $gResponses{$key} }, $resp );
    }
}

################################
# getResponseItem - Pop the next response off the stack unless there is only one,
# in that case just return the last
#
# Arguments:
#   function string
#
# Returns:
#   response string
#
################################
sub getResponseItem($) {
    my ($function) = @_;
    my $response;

    if ( exists( $gResponses{$function} ) ) {
        if ( @{ $gResponses{$function} } > 1 ) {
            $response = shift( @{ $gResponses{$function} } );
        }
        else {
            $response = $gResponses{$function}->[0];
        }
    }
    else {
        mesg("No response for $function");
        return;
    }
    return $response;
}

main;
