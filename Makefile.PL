use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile
  NAME          => "Net::DNAT",
  AUTHOR        => "Rob Brown",
  ABSTRACT_FROM => "lib/Net/DNAT.pm",
  VERSION_FROM	=> "lib/Net/DNAT.pm", # finds $VERSION
  PREREQ_PM    => { # e.g., Module::Name => 1.1
    'Net::Server' => 0.82,
    'IO::Multiplex' => 1.02,
  },
  ;
