##########################
# capture.pl
##########################
use warnings;
use strict;
use Encode;
use utf8;
use open IO => ':encoding(utf8)';

my $opts;

$opts->{connection_config}             = q{$[connection_config]};
$opts->{vcloud_organization}           = q{$[vcloud_organization]};
$opts->{vcloud_virtual_datacenter}     = q{$[vcloud_virtual_datacenter]};
$opts->{vcloud_vappname}               = q{$[vcloud_vappname]};
$opts->{vcloud_new_vapp_template_name} = q{$[vcloud_new_vapp_template_name]};
$opts->{vcloud_new_vapp_template_desc} = q{$[vcloud_new_vapp_template_desc]};
$opts->{vcloud_catalog}                = q{$[vcloud_catalog]};
$[/myProject/procedure_helpers/preamble]

$gt->capture();
exit($opts->{exitcode});
