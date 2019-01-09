##########################
# clone.pl
##########################
use warnings;
use strict;
use Encode;
use utf8;
use open IO => ':encoding(utf8)';

my $opts;

$opts->{connection_config}              = q{$[connection_config]};
$opts->{vcloud_organization}            = q{$[vcloud_organization]};
$opts->{vcloud_virtual_datacenter}      = q{$[vcloud_virtual_datacenter]};
$opts->{vcloud_vappname}                = q{$[vcloud_vappname]};
$opts->{vcloud_new_vappname}            = q{$[vcloud_new_vappname]};
$opts->{vcloud_dest_virtual_datacenter} = q{$[vcloud_dest_virtual_datacenter]};
$opts->{vcloud_create_resource}         = q{1};

$[/myProject/procedure_helpers/preamble]

$gt->clone();
exit($opts->{exitcode});
