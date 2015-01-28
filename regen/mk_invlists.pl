#!perl -w
            use Data::Dumper;
use 5.015;
use strict;
use warnings;
use Unicode::UCD qw(prop_aliases
                    prop_value_aliases
                    prop_invlist
                    prop_invmap search_invlist
                   );
require 'regen/regen_lib.pl';
require 'regen/charset_translations.pl';

# This program outputs charclass_invlists.h, which contains various inversion
# lists in the form of C arrays that are to be used as-is for inversion lists.
# Thus, the lists it contains are essentially pre-compiled, and need only a
# light-weight fast wrapper to make them usable at run-time.

# As such, this code knows about the internal structure of these lists, and
# any change made to that has to be done here as well.  A random number stored
# in the headers is used to minimize the possibility of things getting
# out-of-sync, or the wrong data structure being passed.  Currently that
# random number is:
my $VERSION_DATA_STRUCTURE_TYPE = 148565664;

my $numeric_re = qr/ ^ -? \d+ (:? \. \d+ )? $ /ax;
my $enum_name_re = qr / ^ [[:alpha:]] \w* $/ax;

my $out_fh = open_new('charclass_invlists.h', '>',
		      {style => '*', by => $0,
                      from => "Unicode::UCD"});

my $is_in_ifndef_ext_re = 0;

print $out_fh "/* See the generating file for comments */\n\n";

my %include_in_ext_re = ( NonL1_Perl_Non_Final_Folds => 1 );

my @a2n;

sub uniques {
    # Returns non-duplicated input values.  From "Perl Best Practices:
    # Encapsulated Cleverness".  p. 455 in first edition.

    my %seen;
    return grep { ! $seen{$_}++ } @_;
}

sub a2n($) {
    # Returns the input Unicode code point translated to native.
    my $cp = shift;
    return $cp if $cp !~ $numeric_re || $cp > 255;
    return $a2n[$cp];
}

sub end_ifndef_ext_re {
    if ($is_in_ifndef_ext_re) {
        print $out_fh "\n#endif\t/* #ifndef PERL_IN_XSUB_RE */\n";
        $is_in_ifndef_ext_re = 0;
    }
}

sub output_invlist ($$;$) {
    my $name = shift;
    my $invlist = shift;     # Reference to inversion list array
    my $charset = shift // "";  # name of character set for comment

    die "No inversion list for $name" unless defined $invlist
                                             && ref $invlist eq 'ARRAY'
                                             && @$invlist;

    # Output the inversion list $invlist using the name $name for it.
    # It is output in the exact internal form for inversion lists.

    # Is the last element of the header 0, or 1 ?
    my $zero_or_one = 0;
    if ($invlist->[0] != 0) {
        unshift @$invlist, 0;
        $zero_or_one = 1;
    }
    my $count = @$invlist;

    if ($is_in_ifndef_ext_re) {
        if (exists $include_in_ext_re{$name}) {
            end_ifndef_ext_re;
        }
    }
    elsif (! exists $include_in_ext_re{$name}) {
        print $out_fh "\n#ifndef PERL_IN_XSUB_RE\n" unless exists $include_in_ext_re{$name};
        $is_in_ifndef_ext_re = 1;
    }

    print $out_fh "\nstatic const UV ${name}_invlist[] = {";
    print $out_fh " /* for $charset */" if $charset;
    print $out_fh "\n";

    print $out_fh "\t$count,\t/* Number of elements */\n";
    print $out_fh "\t$VERSION_DATA_STRUCTURE_TYPE, /* Version and data structure type */\n";
    print $out_fh "\t", $zero_or_one,
                  ",\t/* 0 if the list starts at 0;",
                  "\n\t\t   1 if it starts at the element beyond 0 */\n";

    # The main body are the UVs passed in to this routine.  Do the final
    # element separately
    for my $i (0 .. @$invlist - 1) {
        printf $out_fh "\t0x%X", $invlist->[$i];
        print $out_fh "," if $i < @$invlist - 1;
        print $out_fh "\n";
    }

    print $out_fh "};\n";
}

sub add_to_specials ($$) {
    my $specials_ref = shift;
    my $entry = shift;

    # Add '$entry" to @$specials_ref, if not already there.  Regardless, it
    # returns the index into that array that $entry is located at.

    if (! @$specials_ref) {
        push @$specials_ref, "";
        push @$specials_ref, "NaN";
    }

    for my $j (0 .. @$specials_ref - 1) {
        return $j + 1 if $specials_ref->[$j] eq $entry;
    }

    push @$specials_ref, $entry;
    return scalar @$specials_ref;
}

sub output_invmap ($$$$$$$$$$) {
    my $name = shift;
    my $invmap = shift;     # Reference to inversion map array
    my $prop_name = shift;
    my $input_format = shift;
    my $default = shift;
    my $maps_to_code_point = shift;
    my $specials_ref = shift;
    my $force_string = shift;
    my $extra_enums = shift;
    my $charset = shift // "";  # name of character set for comment

    # Output the inversion map $invmap for property $prop_name, but use $name
    # as the actual data structure's name.

    my $count = @$invmap;

    my $output_format;
    my $declaration_type;
    my %enums;

    if ($maps_to_code_point) {
        $output_format = "0x%X";
        $declaration_type = "I32";
    }
    elsif ($input_format =~ /[adi]/) {
        $output_format = "%d";
        my $max = 0;
        my $has_neg = 0;
        for my $value (sort { $a cmp $b } uniques(@$invmap)) {
            my $evaluated = eval $value;
            if (! defined $evaluated || $evaluated eq "") {
                $has_neg = 1;
                next;
            }
            $value = $evaluated;
            if ($value < 0) {
                $has_neg = 1;
                $value = -$value;
            }
            $max = $value if $value > $max;
        }
        $declaration_type = "";
        $declaration_type .= 'unsigned ' unless $has_neg;
        if ($max < 256) {
            $declaration_type .= 'char';
        }
        elsif ($max < 2**31 -1) {
            $declaration_type .= 'int';
        }
        else {
            $declaration_type .= 'long int';
        }
    }
    #elsif ($input_format eq 'f') {
    #    $output_format = "%.1f";
    #    $declaration_type = 'float';
    #}
    elsif ($input_format =~ /[fns]/) {
        $prop_name = (prop_aliases($prop_name))[1]; # Get full name

        if (! $force_string) {
            my @enums = prop_value_aliases($prop_name);
            if (! @enums) {
                die "You specified extra enums '$extra_enums' for a non-enumerated property '$prop_name'" if $extra_enums ne "";
            }
            else {

                # Even if this property is enumerated, if the values aren't legal
                # C names, we can't make it an enumeration.  But the block
                # property is known to have synonyms that are valid legal C, so
                # can skip this for that property.
                if ($prop_name ne 'Block') {
                    for my $value (sort { $a cmp $b } uniques(@$invmap)) {
                        $value = prop_value_aliases("block", $value) if $prop_name eq 'Block';
                        #print STDERR __LINE__, ": '$prop_name' '$value'\n";
                        next if $value =~ $enum_name_re;
                        #print STDERR __LINE__, ": '$prop_name' '$value'\n";
                        goto done_enums;
                    }
                }

                # Convert short names to long, add in the extras, and sort.
                @enums = map { (prop_value_aliases($prop_name, $_))[1] } @enums;
                push @enums, split /,/, $extra_enums if $extra_enums ne "";
                @enums = sort @enums;

                # Assign a value to each element of the enum.  The default
                # value always gets 0; the others are arbitrarily assigned.
                my $enum_val = 0;
                $default = prop_value_aliases($prop_name, $default);
                $enums{$default} = $enum_val++;
                for my $enum (@enums) {
                    $enums{$enum} = $enum_val++ unless exists $enums{$enum};
                }
            }
        }
      done_enums:

        end_ifndef_ext_re;

        if (! %enums) {
            $declaration_type = "char *";
            $output_format = "%s";
        }
        else {
            my $short_name = (prop_aliases($prop_name))[0];

            # The short names tend to be two lower case letters, but it looks
            # better for those if they are upper. XXX
            $short_name = uc($short_name) if length($short_name) < 3
                                             || substr($short_name, 0, 1) =~ /[[:lower:]]/;
            #print $out_fh "\n#define ${short_name}_ENUM_CASE_SHIFT ", int(log(scalar keys %enums) / log(2) + 1), "\n";
            print $out_fh "\n#define ${short_name}_ENUM_COUNT ", scalar keys %enums, "\n";

            $short_name = "PL_$short_name";
            my $enum_count = keys %enums;
            print $out_fh "\ntypedef enum {\n";
            print $out_fh "\t${short_name}_$default = $enums{$default},\n";
            delete $enums{$default};
            foreach my $enum (sort { $a cmp $b } keys %enums) {
                print $out_fh "\t${short_name}_$enum = $enums{$enum}";
                print $out_fh "," if $enums{$enum} < $enum_count - 1;
                print $out_fh  "\n";
            }
            $declaration_type = "${short_name}_enum";
            print $out_fh "} $declaration_type;\n";

            $output_format = "${short_name}_%s";
        }
    }
    else {
        die "'$input_format' invmap() format for '$prop_name' unimplemented";
    }

    die "No inversion map for $prop_name" unless defined $invmap
                                             && ref $invmap eq 'ARRAY'
                                             && $count;

    print $out_fh "\nstatic const $declaration_type ${name}_invmap[] = {";
    print $out_fh " /* for $charset */" if $charset;
    print $out_fh "\n";

    # The main body are the scalars passed in to this routine.
    #print STDERR __LINE__, ": $prop_name: ", Dumper $invmap;
    for my $i (0 .. $count - 1) {
        my $element = $invmap->[$i];
        $element = prop_value_aliases($prop_name, $element) if %enums;
        if (ref $element) {
            #print STDERR __LINE__, ": ", join ", ", @$element, "\n";
            #$str = join "", map { sprintf "\\x%02X", ord $_ } split //, cp_2_utfbytes($U_cp, $charset);
            my $str = "";
            if ($maps_to_code_point) {
                for my $cp (@$element) {
                    $str .= join "", map { sprintf "\\x%02X", ord $_ } split //, cp_2_utfbytes($cp, $charset);
                }
                print $out_fh "\t-", add_to_specials($specials_ref, $str);
            }
            else {
                # See if unique
                print $out_fh "\t\"";
                print $out_fh join " ", @$element;
                print $out_fh "\"";
            }
        }
        elsif ($output_format eq "%s") {
            print $out_fh "\t\"$element\"";
        }
        elsif ($element eq "" || (! %enums
                                  && $element !~ $numeric_re))
        {
            print $out_fh "\t-", add_to_specials($specials_ref, $element);
        }
        else {
            if ($prop_name eq 'Block') {
                $element = prop_value_aliases("block", $element);
            }

            if ($output_format) {
                printf $out_fh "\t$output_format", $element;
            }
            else {
                print $out_fh "\t$element";
            }
        }
        print $out_fh "," if $i < $count - 1;
        print $out_fh  "\n";
    }
    print $out_fh "};\n";

#    if (@specials) {
#        print $out_fh "\nstatic const char * ${name}_specials[] = {";
#        print $out_fh " /* for $charset */" if $charset;
#        print $out_fh "\n";
#
#        for my $i (0 .. @specials - 1) {
#            print $out_fh "\t\"";
#            for my $j (0 .. @{$specials[$i]} - 1) {
#                #printf STDERR "%d: %x\n", __LINE__, $specials[$i][$j];
#                print $out_fh join "", map { sprintf "\\x%02X", ord $_ } split //, cp_2_utfbytes($specials[$i][$j], $charset);
#            }
#            print $out_fh "\"";
#            print $out_fh "," if $i < $count - 1;
#            print $out_fh "\n";
#        }
#
#        print $out_fh "};\n";
#    }

    unless ($is_in_ifndef_ext_re) {
        print $out_fh "\n#ifndef PERL_IN_XSUB_RE\n";
        $is_in_ifndef_ext_re = 1;
    }
}

sub mk_invlist_from_sorted_cp_list {

    # Returns an inversion list constructed from the sorted input array of
    # code points

    my $list_ref = shift;

    return unless @$list_ref;

    # Initialize to just the first element
    my @invlist = ( $list_ref->[0], $list_ref->[0] + 1);

    # For each succeeding element, if it extends the previous range, adjust
    # up, otherwise add it.
    for my $i (1 .. @$list_ref - 1) {
        if ($invlist[-1] == $list_ref->[$i]) {
            $invlist[-1]++;
        }
        else {
            push @invlist, $list_ref->[$i], $list_ref->[$i] + 1;
        }
    }
    return @invlist;
}

# Read in the Case Folding rules, and construct arrays of code points for the
# properties we need.
my ($cp_ref, $folds_ref, $format) = prop_invmap("Case_Folding");
die "Could not find inversion map for Case_Folding" unless defined $format;
die "Incorrect format '$format' for Case_Folding inversion map"
                                                    unless $format eq 'al';
my @has_multi_char_fold;
my @is_non_final_fold;

for my $i (0 .. @$folds_ref - 1) {
    next unless ref $folds_ref->[$i];   # Skip single-char folds
    push @has_multi_char_fold, $cp_ref->[$i];

    # Add to the non-finals list each code point that is in a non-final
    # position
    for my $j (0 .. @{$folds_ref->[$i]} - 2) {
        push @is_non_final_fold, $folds_ref->[$i][$j]
                unless grep { $folds_ref->[$i][$j] == $_ } @is_non_final_fold;
    }
}

sub _Perl_Non_Final_Folds {
    @is_non_final_fold = sort { $a <=> $b } @is_non_final_fold;
    return mk_invlist_from_sorted_cp_list(\@is_non_final_fold);
}

sub prop_name_for_cmp ($) {
    my $name = shift;
    print STDERR __LINE__, ": $name\n";
    $name =~ s/,.*//;
    $name =~ s/[[:^alpha:]]//g;
    return lc $name;
}

sub UpperLatin1 {
    return mk_invlist_from_sorted_cp_list([ 128 .. 255 ]);
}

output_invlist("Latin1", [ 0, 256 ]);
output_invlist("AboveLatin1", [ 256 ]);

end_ifndef_ext_re;

# We construct lists for all the POSIX and backslash sequence character
# classes in two forms:
#   1) ones which match only in the ASCII range
#   2) ones which match either in the Latin1 range, or the entire Unicode range
#
# These get compiled in, and hence affect the memory footprint of every Perl
# program, even those not using Unicode.  To minimize the size, currently
# the Latin1 version is generated for the beyond ASCII range except for those
# lists that are quite small for the entire range, such as for \s, which is 22
# UVs long plus 4 UVs (currently) for the header.
#
# To save even more memory, the ASCII versions could be derived from the
# larger ones at runtime, saving some memory (minus the expense of the machine
# instructions to do so), but these are all small anyway, so their total is
# about 100 UVs.
#
# In the list of properties below that get generated, the L1 prefix is a fake
# property that means just the Latin1 range of the full property (whose name
# has an X prefix instead of L1).
#
# An initial & means to use the subroutine from this file instead of an
# official inversion list.

for my $charset (get_supported_code_pages()) {
    print $out_fh "\n" . get_conditional_compile_line_start($charset);
    print STDERR __LINE__, ": $charset\n";

    @a2n = @{get_a2n($charset)};
                             # Ignore non-alpha in sort
    my @specials;
    no warnings 'qw';
    for my $prop (sort { prop_name_for_cmp($a) cmp prop_name_for_cmp($b) } qw(
                             ASCII
                             Cased
                             VertSpace
                             XPerlSpace
                             XPosixAlnum
                             XPosixAlpha
                             XPosixBlank
                             XPosixCntrl
                             XPosixDigit
                             XPosixGraph
                             XPosixLower
                             XPosixPrint
                             XPosixPunct
                             XPosixSpace
                             XPosixUpper
                             XPosixWord
                             XPosixXDigit
                             _Perl_Any_Folds
                             &NonL1_Perl_Non_Final_Folds
                             _Perl_Folds_To_Multi_Char
                             &UpperLatin1
                             _Perl_IDStart
                             _Perl_IDCont
                             Grapheme_Cluster_Break,EDGE
                           )
    ) {

        # For the Latin1 properties, we change to use the eXtended version of the
        # base property, then go through the result and get rid of everything not
        # in Latin1 (above 255).  Actually, we retain the element for the range
        # that crosses the 255/256 boundary if it is one that matches the
        # property.  For example, in the Word property, there is a range of code
        # points that start at U+00F8 and goes through U+02C1.  Instead of
        # artificially cutting that off at 256 because 256 is the first code point
        # above Latin1, we let the range go to its natural ending.  That gives us
        # extra information with no added space taken.  But if the range that
        # crosses the boundary is one that doesn't match the property, we don't
        # start a new range above 255, as that could be construed as going to
        # infinity.  For example, the Upper property doesn't include the character
        # at 255, but does include the one at 256.  We don't include the 256 one.
        my $prop_name = $prop;
        my $is_local_sub = $prop_name =~ s/^&//;
        my $force_string = $prop_name =~ s/,STRING$//;
        my $extra_enums = "";
        $extra_enums = $1 if $prop_name =~ s/, ( .* ) //x;
        my $lookup_prop = $prop_name;
        my $l1_only = ($lookup_prop =~ s/^L1Posix/XPosix/
                       or $lookup_prop =~ s/^L1//);
        my $nonl1_only = 0;
        $nonl1_only = $lookup_prop =~ s/^NonL1// unless $l1_only;
        ($lookup_prop, my $has_suffixes) = $lookup_prop =~ / (.*) ( , .* )? /x;

        my @invlist;
        my @invmap;
        my $map_format;
        my $map_default;
        my $maps_to_code_point;
        my $to_adjust;
        if ($is_local_sub) {
            @invlist = eval $lookup_prop;
        }
        else {
            @invlist = prop_invlist($lookup_prop, '_perl_core_internal_ok');
            if (! @invlist) {
                my ($list_ref, $map_ref, $format, $default);

                ($list_ref, $map_ref, $format, $default)
                          = prop_invmap($lookup_prop, '_perl_core_internal_ok');
                die "Could not find inversion list for '$lookup_prop'" unless $list_ref;
                @invlist = @$list_ref;
                @invmap = @$map_ref;
                $map_format = $format;
                $map_default = $default;
                $maps_to_code_point = $map_format =~ /x/;
                $to_adjust = $map_format =~ /a/;
            }
        }
        die "Could not find inversion list for '$lookup_prop'" unless @invlist;

        # Re-order the Unicode code points to native ones for this platform.
        # This is only needed for code points below 256, because native code
        # points are only in that range.  For inversion maps of properties
        # where the mappings are adjusted (format =~ /a/), this reordering
        # could mess up the adjustment pattern that was in the input, so that
        # has to be dealt with.
        #
        # And inversion maps that map to code points need to eventually have
        # all those code points remapped to native, and it's better to do that
        # here, going through the whole list not just those below 256.  This
        # is because some inversion maps have adjustments (format =~ /a/)
        # which may be affected by the reordering.  This code needs to be done
        # both for when we are translating the inversion lists for < 256, and
        # for the inversion maps for everything.  By doing both in this loop,
        # we can share that code.  look through the whole of the map array.
        #
        # So, we go through everything for an inversion map to code points;
        # otherwise, we can skip any remapping at all if we are going to
        # output only the above-Latin1 values, or if the range spans the whole
        # of 0..256, as the remap will also include all of 0..256  (256 not
        # 255 because a re-ordering could cause 256 to need to be in the same
        # range as 255.)
        if ((@invmap && $maps_to_code_point)
            || (! $nonl1_only || ($invlist[0] < 256
                                  && ! ($invlist[0] == 0 && $invlist[1] > 256))))
        {

            if (! @invmap) {    # Straight inversion list
            # Look at all the ranges that start before 257.
            my @latin1_list;
            while (@invlist) {
                last if $invlist[0] > 256;
                my $upper = @invlist > 1
                            ? $invlist[1] - 1      # In range

                              # To infinity.  You may want to stop much much
                              # earlier; going this high may expose perl
                              # deficiencies with very large numbers.
                            : $Unicode::UCD::MAX_CP;
                for my $j ($invlist[0] .. $upper) {
                    push @latin1_list, a2n($j);
                }

                shift @invlist; # Shift off the range that's in the list
                shift @invlist; # Shift off the range not in the list
            }

            # Here @invlist contains all the ranges in the original that start
            # at code points above 256, and @latin1_list contains all the
            # native code points for ranges that start with a Unicode code
            # point below 257.  We sort the latter and convert it to inversion
            # list format.  Then simply prepend it to the list of the higher
            # code points.
            @latin1_list = sort { $a <=> $b } @latin1_list;
            @latin1_list = mk_invlist_from_sorted_cp_list(\@latin1_list);
            unshift @invlist, @latin1_list;
            }
            else {  # Is an inversion map

                # This is a similar procedure as plain inversion list, but
                # has multiple buckets.  A plain inversion list just has two
                # buckets, 1) 'in' the list; and 2) not in the list, and we
                # pretty much can ignore the 2nd bucket above, as it is
                # completely defined by the 1st.  But here, what we do is
                # create buckets which contain the code points that map to it,
                # translated to native and turned into an inversion list.
                # Thus each bucket is an inversion list of native code points
                # that map to it or don't map to it.  We use these to create
                # an inversion map for the whole property.
                print STDERR __LINE__, ": charset=$charset: $prop_name: $map_format\n";

                # As mentioned earlier, we use this procedure to not just
                # remap the inversion list to native values, but also the maps
                # of code points to native ones.  In the latter case we have
                # to look at the whole of the inversion map (or at least to
                # above Unicode; as the maps of code points above that should
                # all be to the default).
                my $upper_limit = ($maps_to_code_point) ? 0x10FFFF : 256;

                my %mapped_lists;   # A hash whose keys are the buckets.
                while (@invlist) {
                    last if $invlist[0] > $upper_limit;

                    # This shouldn't actually happen, as prop_invmap() returns
                    # an extra element at the end that is beyond $upper_limit
                    die "inversion map that extends to infinity is unimplemented" unless @invlist > 1;

                    my $bucket;

                    # A hash key can't be a ref (we are only expecting arrays
                    # of scalars here), so convert any such to a string that
                    # will be converted back later.  Even if the mapping is to
                    # code points, we don't translate to native here because
                    # the code output_map() calls to output these arrays
                    # assumes the input is Unicode, not native.
                    if (ref $invmap[0]) {
                        $bucket = join "\cK", @{$invmap[0]};
                    }
                    elsif ($maps_to_code_point && $invmap[0] =~ $numeric_re) {

                        # Do convert to native for maps to single code points.
                        # There are some properties that have a few outlier
                        # maps that aren't code points, so the above test
                        # skips those.
                        $bucket = a2n($invmap[0]);
                    } else {
                        $bucket = $invmap[0];
                    }

                    # We now have the bucket that all code points in the range
                    # map to, though possibly they need to be adjusted.  Go
                    # through the range and put each translated code point in
                    # it into its bucket.
                    my $base_map = $invmap[0];
                    for my $j ($invlist[0] .. $invlist[1] - 1) {
                        if ($to_adjust
                               # The 1st code point doesn't need adjusting
                            && $j > $invlist[0]

                               # Skip any non-numeric maps: these are outliers
                               # that aren't code points.
                            && $base_map =~ $numeric_re

                               #  'ne' because the default can be a string
                            && $base_map ne $map_default)
                        {
                            # We adjust, by incrementing each the bucket and
                            # the map.  For code point maps, translate to
                            # native
                            $base_map++;
                            $bucket = ($maps_to_code_point)
                                      ? a2n($base_map)
                                      : $base_map;
                        }

                        # Add the native code point to the bucket for the
                        # current map
                        push @{$mapped_lists{$bucket}}, a2n($j);
                    } # End of loop through all code points in the range

                    # Get ready for the next range
                    shift @invlist;
                    shift @invmap;
                } # End of loop through all ranges in the map.

                # Here, @invlist and @invmap retain all the ranges from the
                # originals that start with code points above $upper_limit.
                # Each bucket in %mapped_lists contains all the code points
                # that map to that bucket.  If the bucket is for a map to a
                # single code point is a single code point, the bucket has
                # been converted to native.  If something else (including
                # multiple code points), no conversion is done.
                #
                # Now we recreate the inversion map into %xlated, but this
                # time for the native character set.
                my %xlated;
                foreach my $bucket (keys %mapped_lists) {

                    # Sort and convert this bucket to an inversion list.  The
                    # result will be that ranges that start with even-numbered
                    # indexes will be for code points that map to this bucket;
                    # odd ones map to some other bucket, and are discarded
                    # below.
                    @{$mapped_lists{$bucket}}
                                    = sort{ $a <=> $b} @{$mapped_lists{$bucket}};
                    @{$mapped_lists{$bucket}}
                     = mk_invlist_from_sorted_cp_list(\@{$mapped_lists{$bucket}});

                    # Add each even-numbered range in the bucket to %xlated;
                    # so that the keys of %xlated become the range start code
                    # points, and the values are their corresponding maps.
                    while (@{$mapped_lists{$bucket}}) {
                        my $range_start = $mapped_lists{$bucket}->[0];
                        if ($bucket =~ /\cK/) {
                            @{$xlated{$range_start}} = split /\cK/, $bucket;
                        }
                        else {
                            $xlated{$range_start} = $bucket;
                        }
                        shift @{$mapped_lists{$bucket}}; # Discard odd ranges
                        shift @{$mapped_lists{$bucket}}; # Get ready for next
                                                         # iteration
                    }
                } # End of loop through all the buckets.

                # Here %xlated's keys are the range starts of all the code
                # points in the inversion map.  Construct an inversion list
                # from them.
                my @new_invlist = sort { $a <=> $b } keys %xlated;

                # If the list is adjusted, we want to munge this list so that
                # we only have one entry for where consecutive code points map
                # to consecutive values.  We just skip the subsequent entries
                # where this is the case.
                if ($to_adjust) {
                    my @temp;
                    for my $i (0 .. @new_invlist - 1) {
                        next if $i > 0
                                && $new_invlist[$i-1] + 1 == $new_invlist[$i]
                                && $xlated{$new_invlist[$i-1]} =~ $numeric_re
                                && $xlated{$new_invlist[$i]} =~ $numeric_re
                                && $xlated{$new_invlist[$i-1]} + 1 == $xlated{$new_invlist[$i]};
                        push @temp, $new_invlist[$i];
                    }
                    @new_invlist = @temp;
                }

                # The inversion map comes from %xlated's values.  We can
                # unshift each onto the front of the untouched portion, in
                # reverse order of the portion we did process.
                foreach my $start (reverse @new_invlist) {
                    unshift @invmap, $xlated{$start};
                }

                # Finally prepend the inversion list we have just constructed to the
                # one that contains anything we didn't process.
                unshift @invlist, @new_invlist;
            }
        }

        # prop_invmap() returns an extra final entry, which we can now
        # discard.
        if (@invmap) {
            pop @invlist;
            pop @invmap;
        }

        if ($l1_only) {
            die "Unimplemented to do a Latin-1 only inversion map" if @invmap;
            for my $i (0 .. @invlist - 1 - 1) {
                if ($invlist[$i] > 255) {

                    # In an inversion list, even-numbered elements give the code
                    # points that begin ranges that match the property;
                    # odd-numbered give ones that begin ranges that don't match.
                    # If $i is odd, we are at the first code point above 255 that
                    # doesn't match, which means the range it is ending does
                    # match, and crosses the 255/256 boundary.  We want to include
                    # this ending point, so increment $i, so the splice below
                    # includes it.  Conversely, if $i is even, it is the first
                    # code point above 255 that matches, which means there was no
                    # matching range that crossed the boundary, and we don't want
                    # to include this code point, so splice before it.
                    $i++ if $i % 2 != 0;

                    # Remove everything past this.
                    splice @invlist, $i;
                    splice @invmap, $i if @invmap;
                    last;
                }
            }
        }
        elsif ($nonl1_only) {
            my $found_nonl1 = 0;
            for my $i (0 .. @invlist - 1 - 1) {
                next if $invlist[$i] < 256;

                # Here, we have the first element in the array that indicates an
                # element above Latin1.  Get rid of all previous ones.
                splice @invlist, 0, $i;
                splice @invmap, 0, $i if @invmap;

                # If this one's index is not divisible by 2, it means that this
                # element is inverting away from being in the list, which means
                # all code points from 256 to this one are in this list (or
                # map to the default for inversion maps)
                if ($i % 2 != 0) {
                    unshift @invlist, 256;
                    unshift @invmap, $map_default if @invmap;
                }
                $found_nonl1 = 1;
                last;
            }
            die "No non-Latin1 code points in $lookup_prop" unless $found_nonl1;
        }

        output_invlist($prop_name, \@invlist, $charset);
        output_invmap($prop_name, \@invmap, $lookup_prop, $map_format, $map_default, $maps_to_code_point, \@specials, $force_string, $extra_enums, $charset) if @invmap;
    }
    end_ifndef_ext_re;

    if (@specials) {
        print $out_fh "\nstatic const char * PL_invmap_specials[] = {";
        print $out_fh " /* for $charset */" if $charset;
        print $out_fh "\n";

        for my $i (0 .. @specials - 1) {
            print $out_fh "\t\"$specials[$i]\"";
            print $out_fh "," if $i < @specials - 1;
            print $out_fh "\n";
        }

        print $out_fh "};\n";
    }
    print $out_fh "\n" . get_conditional_compile_line_end();
}

my @sources = ($0, "lib/Unicode/UCD.pm");
{
    # Depend on mktables’ own sources.  It’s a shorter list of files than
    # those that Unicode::UCD uses.
    open my $mktables_list, "lib/unicore/mktables.lst"
        or die "$0 cannot open lib/unicore/mktables.lst: $!";
    while(<$mktables_list>) {
        last if /===/;
        chomp;
        push @sources, "lib/unicore/$_" if /^[^#]/;
    }
}
read_only_bottom_close_and_rename($out_fh, \@sources)
