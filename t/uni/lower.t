BEGIN {
    chdir 't' if -d 't';
    require "uni/case.pl";
}

casetest(0, # No extra tests run here,
	"Lowercase_Mapping",
        lc                             => sub { lc $_[0] },
	lc_with_appended_null_arg      => sub { my $a = ""; lc ($_[0] . $a) },
	lcfirst                        => sub { lcfirst $_[0] },
	lcfirst_with_appended_null_arg => sub { my $a = ""; lcfirst ($_[0] . $a) }
       );
