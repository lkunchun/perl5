# Helper for some of the .t's in this directory

sub native_to_uni($) {
    my $string = shift;

    return $string if ord("A") == 65;
    my $output = "";
    for my $i (0 .. length($string) - 1) {
        $output .= chr(utf8::native_to_unicode(ord(substr($string, $i, 1))));
    }
    # Preserve utf8ness of input onto the output, even if it didn't need to be
    # utf8
    utf8::upgrade($output) if utf8::is_utf8($string);

    return $output;
}


sub ascii_order {   # Sort helper
    return native_to_uni($a) cmp native_to_uni($b);
}

1
