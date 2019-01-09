use ElectricCommander;

push (@::gMatchers,  
  {
        id =>          "capturevAppTemplate",
        pattern =>     q{^VApp\s+\'(.+)\'\s+succesfully.+\'(.+)\'},
        action =>           q{
         
                              my $desc = ((defined $::gProperties{"summary"}) ? $::gProperties{"summary"} : '');

                              $desc .= "Captured \'$1\' as \'$2\' template.";
                              
                              setProperty("summary", $desc . "\n");
                             },
  },
  {
        id =>          "provisionVMSuccesful",
        pattern =>     q{^Created\sresource\sfor\s+\'(.+)\'\s+as\s+(.+)},
        action =>           q{
         
                              my $desc = ((defined $::gProperties{"summary"}) ? $::gProperties{"summary"} : '');

                              $desc .= "Created resource for \'$1\' as \'$2\'.";
                              
                              setProperty("summary", $desc . "\n");
                             },
  },
    {
        id =>          "cleanupResourceSuccesful",
        pattern =>     q{^Resource\s+\'(.+)\'\s+deleted},  
        action =>           q{
         
                              my $desc = ((defined $::gProperties{"summary"}) ? $::gProperties{"summary"} : '');

                              $desc .= "Deleted resource: \'$1\'.";
                              
                              setProperty("summary", $desc . "\n");
                             },
  },
  
  {
        id =>          "cleanupvAppSuccesful",
        pattern =>     q{^vApp\s+\'(.+)\'\s+succesfully\s+deleted},  
        action =>           q{
         
                              my $desc = ((defined $::gProperties{"summary"}) ? $::gProperties{"summary"} : '');

                              $desc .= "Deleted vApp: \'$1\'.";
                              
                              setProperty("summary", $desc . "\n");
                             },
  },
  
    {
        id =>          "clonevAppSuccesful",
        pattern =>     q{^vApp\s+\'(.+)\'\s+succesfully\s+cloned\s+.+\'(.+)\'},  
        action =>           q{
         
                              my $desc = ((defined $::gProperties{"summary"}) ? $::gProperties{"summary"} : '');

                              $desc .= "Cloned vApp \'$1\' as \'$2\'.";
                              
                              setProperty("summary", $desc . "\n");
                             },
  },
  
  {
        id =>          "procedurevAppError",
        pattern =>     q{Failed:\s(.*)\swith\smessage\s(.+)},
        action =>           q{
         
                              my $desc = ((defined $::gProperties{"summary"}) ? $::gProperties{"summary"} : '');

                              $desc .= "Error $1: $2";
                              
                              setProperty("summary", $desc . "\n");
                             },
  },
  
  {
        id =>          "provisionVMFailure",
        pattern =>     q{Cannot\s(.*)},
        action =>           q{
         
                              my $desc = ((defined $::gProperties{"summary"}) ? $::gProperties{"summary"} : '');

                              $desc .= "Error: Cannot $1";
                              
                              setProperty("summary", $desc . "\n");
                              setProperty("outcome", "error");
                             },
  },
  
  {
        id =>          "GetvAppFailure",
        pattern =>     q{(.*)vApp:\s(.+)\s+not\s+found.},
        action =>           q{
         
                              my $desc = ((defined $::gProperties{"summary"}) ? $::gProperties{"summary"} : '');

                              $desc .= "Error: vApp $2 not found";
                              
                              setProperty("summary", $desc . "\n");                              
                             },
  },
  {
        id =>          "failure",
        pattern =>     q{(.*)Failed\sto\s(.+).},
        action =>           q{
         
                              my $desc = ((defined $::gProperties{"summary"}) ? $::gProperties{"summary"} : '');

                              $desc .= "Failed to $2 ";
                              
                              setProperty("summary", $desc . "\n");                              
                             },
  },
  {
        id =>          "taskfailure",
        pattern =>     q{^Task\sstatus\s-1:},
        action =>           q{
         
                              my $desc = ((defined $::gProperties{"summary"}) ? $::gProperties{"summary"} : '');

                              $desc .= "The object could not be created.";
                              
                              setProperty("summary", $desc . "\n");                              
                             },
  },
);
