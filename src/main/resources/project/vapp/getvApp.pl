##########################
# cleanup.pl
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
$opts->{tag}                       = q{$[tag]};
$opts->{results}                   = q{$[results]};

$[/myProject/procedure_helpers/preamble]

$gt->get_vapp();
exit($opts->{exitcode});
