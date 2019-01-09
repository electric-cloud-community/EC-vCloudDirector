##########################
# provision.pl
##########################
use warnings;
use strict;
use Encode;
use utf8;
use open IO => ':encoding(utf8)';

my $opts;

$opts->{connection_config}         = q{$[connection_config]};
$opts->{vcloud_organization}       = q{$[vcloud_organization]};
$opts->{vcloud_catalog}            = q{$[vcloud_catalog]};
$opts->{vcloud_template}           = q{$[vcloud_template]};
$opts->{vcloud_virtual_datacenter} = q{$[vcloud_virtual_datacenter]};
$opts->{vcloud_vappname}           = q{$[vcloud_vappname]};
$opts->{vcloud_vapp_hostname}      = q{$[vcloud_vapp_hostname]};
$opts->{vcloud_network}            = q{$[vcloud_network]};
$opts->{vcloud_parent_network}     = q{$[vcloud_parent_network]};
$opts->{vcloud_fenced_mode}        = q{$[vcloud_fenced_mode]};
$opts->{tag}                       = q{$[tag]};
$opts->{results}                   = q{$[results]};
$opts->{vclouddirector_pools}      = q{$[pools]};
$opts->{vcloud_create_resource}    = q{$[vcloud_create_resource]};
$opts->{vcloud_dns_wait_time} 	   = q{$[vcloud_dns_wait_time]};
$opts->{vcloud_poweroff_vapp}      = q{$[vcloud_poweroff_vapp]};

# default behaviour, for system tests and pre-created configurations
if ($opts->{vcloud_create_resource} !~ m/^[\d]$/s) {
	$opts->{vcloud_create_resource} = 1;
}

$[/myProject/procedure_helpers/preamble]

$gt->provision();
exit($opts->{exitcode});
