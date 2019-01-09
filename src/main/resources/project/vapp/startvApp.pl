##########################
# startvApp.pl
##########################
use warnings;
use strict;
use Encode;
use utf8;
use open IO => ':encoding(utf8)';

my $opts;

$opts->{connection_config}         = q{$[connection_config]};
$opts->{vcloud_organization}       = q{$[vcloud_organization]};
$opts->{vcloud_virtual_datacenter} = q{$[vcloud_virtual_datacenter]};
$opts->{vcloud_vappname}           = q{$[vcloud_vappname]};
$opts->{vcloud_create_resource}    = q{$[vcloud_create_resource]};
$opts->{tag}                       = q{$[tag]};
$opts->{results}                   = q{$[results]};
$opts->{vclouddirector_pools}      = q{$[pools]};

$[/myProject/procedure_helpers/preamble]

$gt->start_vapp();
exit($opts->{exitcode});
