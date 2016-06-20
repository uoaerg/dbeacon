#!/usr/bin/perl -w

# matrix.pl - displays dbeacon dump information in a matrix,
#		or stores it in RRD files and displays it
#
# To use it you can add this line in your apache config file:
# ScriptAlias /matrix/ /path/to/dbeacon/contrib/matrix.pl
#
# by Hugo Santos, Sebastien Chaumontet and Hoerdt Micka�l
#
#   Perl code improvement suggestions by Marco d'Itri

use CGI;
use XML::Parser;
use POSIX qw(strftime);
use Time::HiRes qw(gettimeofday tv_interval);
use strict;

# configuration variables, may be changed in matrix.conf
our $beacon_config_base = '/nosuchdir';
our $dumpfile = '/var/lib/dbeacon/dump.xml';
our $historydir = 'data';
our $verbose = 1;
our $title = 'IPv6 Multicast Beacon';
our $page_title = $title;
our $default_hideinfo = 0;	# one of '0', '1'
our $default_what = 'ssmorasm';	# one of 'ssmorasm', 'both', 'asm'
our $history_enabled = 0;
our $css_file;
our $dump_update_delay = 5;	# time between each normal dumps
				# (used to detect outdated dump files)
our $flag_url_format = 'http://www.sixxs.net/gfx/countries/%s.gif';
our $default_ssm_group = 'ff3e::beac/10000';
our $debug = 0;
our $matrix_link_title = 0;
our $default_full_matrix = 0;
our $faq_page = 'http://fivebits.net/proj/dbeacon/wiki/FAQ';

our $max_beacon_name_length = 30;

our ($row_block, $column_block) = (15, 15);  # Repeat row/column headings

my $ssm_ping_url = 'http://www.venaas.no/multicast/ssmping/';

my $histbeacmatch;

if (exists $ENV{'DBEACON_CONF'}) {
	do $ENV{'DBEACON_CONF'} or die "Failed to open configuration: $!";
} else {
	if (-f '/etc/dbeacon/matrix/matrix.conf') {
		do '/etc/dbeacon/matrix/matrix.conf';
	} elsif (-f '/etc/dbeacon/matrix.conf') {
		do '/etc/dbeacon/matrix.conf';
	}

	if (-f 'matrix.conf') {
		do 'matrix.conf';
	}
}

my $RRDs = "RRDs";

if ($history_enabled) {
	eval "use $RRDs";
	die ("RRDs not available: $!") if ($@);
}

if (exists $ENV{'DBEACON_DUMP'}) {
	$dumpfile = $ENV{'DBEACON_DUMP'};
}

my $dbeacon = '<a href="http://fivebits.net/proj/dbeacon/">dbeacon</a>';

use constant NEIGH => 0;
use constant IN_EDGE => 1;
use constant OUT_EDGE => 2;
use constant NAME => 3;
use constant CONTACT => 4;
use constant COUNTRY => 5;
use constant AGE => 6;
use constant URL => 7;
use constant LG => 8;
use constant MATRIX => 9;
use constant RX_LOCAL => 10;
use constant SSM_PING => 11;

my %adj;

my $sessiongroup;
my $ssm_sessiongroup;

my $load_start = [gettimeofday];
my $ended_parsing_dump;

exit store_data($ARGV[0]) if scalar(@ARGV) > 0;

my $page = new CGI;
my $url = $page->script_name().'?';

my $dst = $page->param('dst');
my $src = $page->param('src');
my $type = $page->param('type');
my $age = $page->param('age');
my $at = $page->param('at');

my $beacon_id = $page->param('id');
if ($beacon_id) {
    -d $beacon_config_base && -f "$beacon_config_base/$beacon_id/matrix.conf" 
	&& do "$beacon_config_base/$beacon_id/matrix.conf";
    $url .= "id=".$beacon_id."&amp;";
}

my %ages = (
	'-1h' => 'Hour',
	'-6h' => '6 Hours',
	'-12h' => '12 Hours',
	'-1d' => 'Day',
	'-1w' => 'Week',
	'-1m' => 'Month',
	'-1y' => 'Year');

my @propersortedages = ('-1m', '-1w', '-1d', '-12h', '-6h', '-1h');

$age ||= '-1d';

my $outb = '';

sub printx {
	$outb .= join '', @_;
}

sub send_page {
	print $page->header(-Content_length => length $outb);
	print $outb;
}

if ($history_enabled and defined $page->param('img')) {
	$|=1;
	graphgen();

} elsif ($history_enabled and defined $page->param('history')) {
	list_graph();

	send_page;
} else {
	my ($start, $step);

	if (defined $page->param('at') and $page->param('at') =~ /^\d+$/) {
		# Build matrix from old data
		($start, $step) = build_vertex_from_rrd();
	} else {
		# Buils matrix from live data
		parse_dump_file($dumpfile);
	}

	render_matrix($start, $step);

	send_page;
}

sub hist_beacon_dir {
	my ($beac) = @_;

	return "$historydir/$beac";
}

sub hist_beacon_sources_dir {
	return hist_beacon_dir(@_) . "/sources";
}

sub build_vertex_one {
	my ($dstaddr, $srcaddr, $index, $path) = @_;

	my ($start, $step, $names, $data);

	($start, $step, $names, $data) =
		$RRDs::{fetch}($path, 'AVERAGE', '-s',
		$page->param('at'), '-e', $page->param('at'));

	return [-1, -1] if $RRDs::{error};

	if (not defined($adj{$srcaddr})) {
		$adj{$srcaddr}[IN_EDGE] = 0;
		$adj{$srcaddr}[OUT_EDGE] = 0;
	}

	for (my $i = 0; $i < $#$names+1; $i++) {
		if (defined $$data[0][$i]) {
			if ($$names[$i] =~ /^(delay|jitter)$/) {
				$$data[0][$i] *= 1000;
			}

			if (not defined $adj{$dstaddr}[NEIGH]{$srcaddr}) {
				$adj{$dstaddr}[IN_EDGE] ++;
				$adj{$srcaddr}[OUT_EDGE] ++;
			}

			$adj{$dstaddr}[NEIGH]{$srcaddr}[0] ++;
			$adj{$dstaddr}[NEIGH]{$srcaddr}[$index]{$$names[$i]} = $$data[0][$i];
		}
	}

	return ($start, $step);
}

sub build_vertex_from_rrd {
	my ($start, $step);

	foreach my $dstbeacon (get_beacons()) {
		my ($dstname, $dstaddr) = get_name_from_host($dstbeacon->[0]);

		if (defined $dstaddr) {
			if (not defined $adj{$dstaddr}) {
				$adj{$dstaddr}[IN_EDGE] = 0;
				$adj{$dstaddr}[OUT_EDGE] = 0;
			}

			$adj{$dstaddr}[NAME] = $dstname;
			$adj{$dstaddr}[CONTACT] = $dstbeacon->[3];
			$adj{$dstaddr}[COUNTRY] = $dstbeacon->[4];
			$adj{$dstaddr}[URL] = $dstbeacon->[5];
			$adj{$dstaddr}[MATRIX] = $dstbeacon->[6];
			$adj{$dstaddr}[LG] = $dstbeacon->[7];

			foreach my $srcbeacon (get_sources($dstbeacon->[0])) {
				$adj{$srcbeacon->[3]}[NAME] = $srcbeacon->[3]
					if defined $srcbeacon->[3];

				if (defined $srcbeacon->[5]) {
					my ($s1, $s2) =
						build_vertex_one($dstaddr,
							$srcbeacon->[4], 1,
							$srcbeacon->[5]);
					$start ||= $s1;
					$step ||= $s2;
				}

				if (defined $srcbeacon->[6]) {
					my ($s1, $s2) =
						build_vertex_one($dstaddr,
							$srcbeacon->[4], 2,
							$srcbeacon->[6]);
					$start ||= $s1;
					$step ||= $s2;
				}
			}
		}
	}

	return ($start, $step);
}

sub full_url0 {
	return $url."dst=$dst&amp;src=$src";
}

sub full_url {
	$type ||= 'ttl';
	return $url."dst=$dst&amp;src=$src&amp;type=$type";
}

sub parse_dump_file {
	my ($dump) = @_;

	my $parser = new XML::Parser(Style => 'Tree');
	$parser->setHandlers(Start => \&start_handler);
	my $tree = $parser->parsefile($dump);

	$ended_parsing_dump = [gettimeofday];
}

sub last_dump_update {
	return (stat($dumpfile))[9];
}

sub check_outdated_dump {
	my $last_update_time = last_dump_update;

	if ($last_update_time + ($dump_update_delay * 2) < time) {
		return $last_update_time;
	} else {
		return 0;
	}
}

sub beacon_name {
	my ($d) = @_;

	if ($adj{$d}[NAME] ne '') {
		return $adj{$d}[NAME];
	} else {
		$d =~ s/\/\d+$//;
		return "Unknown ($d)";
	}
}

sub beacon_short_name {
	my ($d) = @_;

	my $name = beacon_name($d);
	if (length($name) > $max_beacon_name_length) {
		$name = substr($name, 0, 17);
		$name .= '...';
	}

	return $name;
}

sub make_history_url {
	my ($dst, $src, $type) = @_;

	return $url."history=1&amp;src=" . $src . ".$type&amp;dst=" . $dst;
}

sub make_history_urlx {
	my ($dst, $src, $type) = @_;

	my $dstbeacon = $dst->[0];
	my $srcbeacon = $src->[0];

	$dstbeacon =~ s/\/\d+$//;
        $srcbeacon =~ s/\/\d+$//;

	return $url."history=1&amp;src=" . $dst->[1] . "-$dstbeacon.$type&amp;"
				. 'dst=' . $src->[1] . "-$srcbeacon";
}

sub build_name {
	my ($a) = @_;

	return [$a, $adj{$a}[NAME]];
}

sub make_history_link {
	my ($dst, $src, $type, $txt, $class) = @_;

	my $dstname = build_name($dst);
	my $srcname = build_name($src);

	if ($history_enabled) {
		printx '<a class="', $class, '" href="';
		printx make_history_urlx($dstname, $srcname, $type) . '"';
	} else {
		printx '<span';
	}

	if ($matrix_link_title) {
		printx ' title="', $srcname->[1], ' <- ', $dstname->[1], '"';
	}
	printx '>', $txt;

	if ($history_enabled) {
		printx '</a>';
	} else {
		printx '</span>';
	}
}

sub make_matrix_cell {
	my ($dst, $src, $type, $txt, $class) = @_;

	if (not defined($txt)) {
		printx '<td class="noinfo_', $type, '">-</td>';
	} else {
		printx '<td class="A_', $type, '">';
		make_history_link($dst, $src, $type, $txt, $class);
		printx '</td>';
	}
}

sub format_date {
	my $tm = shift;

	if (not $tm) {
		return "-";
	}

	my $res;
	my $dosecs = 1;

	if ($tm > 86400) {
		$res .= sprintf " %id", $tm / 86400;
		$tm = $tm % 86400;
		$dosecs = 0;
	}

	if ($tm > 3600) {
		$res .= sprintf " %ih", $tm / 3600;
		$tm = $tm % 3600;
	}

	if ($tm > 60) {
		$res .= sprintf " %im", $tm / 60;
		$tm = $tm % 60;
	}

	if ($dosecs and $tm > 0) {
		$res .= " $tm";
		$res .= "s";
	}

	return $res;
}

my $current_beacon;
my $current_source;

sub start_handler {
	my ($p, $tag, %atts) = @_;
	my $name;
	my $value;

	if ($tag eq 'group') {
		$sessiongroup = $atts{'addr'};
		$ssm_sessiongroup = $atts{'ssmgroup'};
	} elsif ($tag eq 'beacon') {
		$current_beacon = $atts{'addr'};
		$current_source = '';

		if ($atts{'addr'} and $atts{'name'} and $atts{'age'} > 0) {
			$adj{$current_beacon}[NAME] = $atts{'name'};
			$adj{$current_beacon}[CONTACT] = $atts{'contact'};
			$adj{$current_beacon}[AGE] = $atts{'age'};
			$adj{$current_beacon}[COUNTRY] = uc $atts{'country'} if defined $atts{'country'};
			$adj{$current_beacon}[RX_LOCAL] = $atts{'rxlocal'} if defined $atts{'rxlocal'};
		}
	} elsif ($tag eq 'asm' or $tag eq 'ssm') {
		foreach my $att ("ttl","loss","delay","jitter") {
			if (defined $atts{$att}) {
				my $index = $tag eq 'ssm' ? 2 : 1;

				if (not defined $adj{$current_beacon}[NEIGH]{$current_source}) {
					$adj{$current_beacon}[IN_EDGE] ++;
					$adj{$current_source}[OUT_EDGE] ++;
				}

				$adj{$current_beacon}[NEIGH]{$current_source}[0] ++;
				$adj{$current_beacon}[NEIGH]{$current_source}[$index]{$att} = $atts{$att};
			}
		}
	} elsif ($tag eq 'source') {
		$current_source = $atts{'addr'};

		if (defined $atts{'name'} and defined $atts{'addr'}) {
			$adj{$current_source}[NAME] = $atts{'name'} if defined $atts{'name'};
			$adj{$current_source}[CONTACT] = $atts{'contact'} if defined $atts{'contact'};
			$adj{$current_source}[COUNTRY] ||= uc $atts{'country'} if defined $atts{'country'};
		}
	} elsif ($tag eq 'website') {
		if ($atts{'type'} ne '' and $atts{'url'} ne '') {
			if ($atts{'type'} eq 'generic') {
				$adj{$current_source or $current_beacon}[URL] = $atts{'url'};
			} elsif ($atts{'type'} eq 'lg') {
				$adj{$current_source or $current_beacon}[LG] = $atts{'url'};
			} elsif ($atts{'type'} eq 'matrix') {
				$adj{$current_source or $current_beacon}[MATRIX] = $atts{'url'};
			}
		}
	} elsif ($tag eq 'flag') {
		if ($atts{'name'} eq 'SSMPing' and $atts{'value'} eq 'true') {
			$adj{$current_beacon}[SSM_PING] = 1;
		}
	}
}

sub start_document {
	my ($additionalinfo) = @_;

	start_base_document();

	printx '<h1 style="margin: 0">', $title, '</h1>', "\n";

	printx '<p style="margin: 0"><small>Current server time is ', localtime() . $additionalinfo, '</small></p>', "\n";
}

sub build_header {
	my ($attname, $atthideinfo, $attwhat, $full_matrix, $show_lastupdate, $start, $step) = @_;

	if (defined $step) { # From history
		printx "<p><b>Snapshot stats at " . localtime($start) . "</b> ($step seconds average)</p>\n";

	# if (defined $page->param('at')) {

		printx '<form id="timenavigator" action=";">';
		printx '<script type="text/javascript">
			function move(way) {
				var timenavoff = document.getElementById("timenavigator").offset;
				var selectedvalue = timenavoff.options[timenavoff.selectedIndex].value;
				var newdate = ' . $at . ' + selectedvalue * way;
				var url = "' . $url."what=$attwhat&amp;att=$attname" . '&amp;ammount=" + selectedvalue + "&amp;at="+newdate;
				location.href = url;
			}
			</script>';

		printx '<p>Time navigation: ';
		printx '<a href="javascript:move(-1)"><small>Move backward</small> &lt;</a>';

		printx '<select name="offset" style="margin-left: 0.5em; margin-right: 0.5em">'."\n";

		my $ammount = $page->param('ammount');
		$ammount ||= 60;

		my @ammounts = ([60, '60 s'], [600, '10m'], [3600, '1h'], [14400, '4h'], [43200, '12h'], [86400, '24h'], [604800, '7d'], [2592000, '30d']);
		# 7884000 3 months

		foreach my $ammitem (@ammounts) {
			printx '<option value="' . $ammitem->[0] . '"';
			printx ' selected="selected"' if $ammitem->[0] == $ammount;
			printx '> ' . $ammitem->[1] . '</option>';
		}

		printx "</select>";

		printx '<a href="javascript:move(1)">&gt; <small>Move forward</small></a>';
		printx '</p></form>';

	} else {
		my $last_update = last_dump_update;

		printx '<p><b>Current stats for</b> <code>', $sessiongroup, '</code>';
		printx ' (SSM: <code>', $ssm_sessiongroup, '</code>)' if $ssm_sessiongroup;
		printx ' <small>[Last update: ', format_date(time - $last_update), ' ago]</small>' if $show_lastupdate;
		printx '</p>';

		my $last_update_time = check_outdated_dump;
		if ($last_update_time) {
			printx '<p style="color: red">Warning: outdated informations, last dump was updated ';
			printx localtime($last_update_time) . "</p>\n";
		}
	}

	my $hideatt;

	$hideatt = 'hideinfo=1&amp;' if $atthideinfo;

	my $whatatt = "what=$attwhat&amp;";
	my $fullatt = "full=$full_matrix&amp;";

	my @view = qw(ttl loss delay jitter);
	my @view_name = ('TTL', 'Loss', 'Delay', 'Jitter');
	my @view_type = ('hop count', 'percentage', 'ms', 'ms');

	my @sources = qw(asm ssm both ssmorasm);
	my @sources_name = ('ASM', 'SSM', 'Both', 'SSM or ASM');

	my $view_len = scalar(@view);
	my $i;

	printx '<p style="margin: 0"><span style="float: left"><b>View</b>';

	do_faq_qlink('views');

	$attname ||= '';
	$hideatt ||= '';
	$at ||= '';

	printx ' <small>(';

	if (not $atthideinfo) {
		printx "<a href=\"".$url."hideinfo=1&amp;$fullatt$whatatt&amp;att=$attname&amp;at=$at\">Hide Source Info</a>";
	} else {
		printx "<a href=\"".$url."hideinfo=0&amp;$fullatt$whatatt&amp;att=$attname&amp;at=$at\">Show Source Info</a>";
	}

	printx ", <a href=\"$url$hideatt&amp;$whatatt&amp;att=$attname&amp;at=$at&amp;full=" . (!$full_matrix) . '">' . ($full_matrix ? 'Condensed' : 'Full') . '</a>';

	for (my $k = 0; $k < scalar(@sources); $k++) {
		printx ', ';
		if ($sources[$k] ne $attwhat) {
			printx '<a href="', $url, $hideatt, $fullatt, '&amp;what=', $sources[$k];
			printx '&amp;att=', $attname, '&amp;at=', $at, '">';
		}
		printx $sources_name[$k];
		if ($sources[$k] ne $attwhat) {
			printx '</a>';
		}
	}

	#if ($attwhat eq "asm") {
	#	printx ", <a href=\"$url$hideatt$fullatt&amp;what=both&amp;att=$attname&amp;at=$at\">ASM and SSM</a>";
	#	printx ", <a href=\"$url$hideatt$fullatt&amp;what=ssmorasm&amp;att=$attname&amp;at=$at\">SSM or ASM</a>";
	#} elsif ($attwhat eq "ssmorasm") {
	#	printx ", <a href=\"$url$hideatt$fullatt&amp;what=both&amp;att=$attname&amp;at=$at\">ASM and SSM</a>";
	#	printx ", <a href=\"$url$hideatt$fullatt&amp;what=asm&amp;att=$attname&amp;at=$at\">ASM only</a>";
	#} else {
	#	printx ", <a href=\"$url$hideatt$fullatt&amp;what=ssmorasm&amp;att=$attname&amp;at=$at\">SSM or ASM</a>";
	#	printx ", <a href=\"$url$hideatt$fullatt&amp;what=asm&amp;att=$attname&amp;at=$at\">ASM only</a>";
	#}

	printx ')</small>:</span></p>';

	printx '<ul id="view">', "\n";
	for ($i = 0; $i < $view_len; $i++) {
		my $att = $view[$i];
		my $attn = $view_name[$i];
		printx '<li>';
		if ($attname eq $att) {
			printx '<span class="viewitem" id="currentview">', $attn, '</span>';
		} else {
			printx "<a class=\"viewitem\" href=\"$url$hideatt$fullatt$whatatt" . "att=$att&amp;at=$at\">$attn</a>";
		}
		printx ' <small>(', $view_type[$i], ')</small></li>', "\n";
	}
	printx '</ul>', "\n";

	printx '<p style="margin: 0; margin-bottom: 1em">&nbsp;</p>';
}

sub end_document {
	printx '<hr />', "\n";

	printx '<p style="margin: 0"><small>matrix.pl - a tool for dynamic viewing of ', $dbeacon, ' information and history.';
	printx ' by Hugo Santos, Sebastien Chaumontet and Hoerdt Micka�l</small></p>', "\n";

	if ($debug) {
		my $render_end = [gettimeofday];
		my $diff = tv_interval $load_start, $render_end;

		printx '<p style="margin: 0; color: #888"><small>Took ', (sprintf "%.3f", $diff), ' seconds from load to end of render';
		if (defined($ended_parsing_dump)) {
			my $dumpdiff = tv_interval $load_start, $ended_parsing_dump;
			printx ' (', (sprintf "%.3f", $dumpdiff), ' in parsing dump file)';
		}
		printx '.</small></p>', "\n";
	}

	printx '</body>', "\n";
	printx '</html>', "\n";
}

sub make_ripe_search_url {
	my ($ip) = @_;

	return "http://www.ripe.net/whois?form_type=simple&amp;full_query_string=&amp;searchtext=$ip&amp;do_search=Search";
}

sub do_faq_link {
	my ($txt, $ctx) = @_;

	if ($faq_page) {
		printx ' <a style="text-decoration: none" href="', $faq_page, '#', $ctx;
		printx '">', $txt, '</a>';
	} else {
		printx $txt;
	}
}

sub do_faq_qlink {
	my $ctx = shift;

	return do_faq_link('<small>[?]</small>', $ctx);
}

sub make_flag_url {
	my ($country) = @_;

	return '<img src="' .
		sprintf($flag_url_format, lc $country) .
		'" alt="', $country, '" style="vertical-align: middle; border: 1px solid black" />';
}

sub make_cell_class {
	my ($base, $val) = @_;

	my $tok = 'full';
	if ($val >= 0.05) {
		$tok = 'almst';
	} elsif ($val >= 0.40) {
		$tok = 'low';
	}

	return $tok . '_' . $base;
}

sub print_beacord {
	my ($id) = @_;

	return '<span class="beacord">' . $id . '</span>';
}

sub print_beacord_name {
	my ($id, $name) = @_;

	return print_beacord($id) . ' ' . beacon_name($name);
}

sub obsf_email {
	my ($mail) = @_;

	return '-' if not defined $mail or $mail eq '';

	my $res = '';

	foreach my $c (split //, $mail) {
		$res .= '&#' . ord($c);
	}

	return $res;
}

sub column_header($$$) {
	my ($rx, $what_td, $ids) = @_;

	printx '<tr><td class="beacname style="font-style: italic" colspan="2"><span style="font-size: 75%">&darr; Sources \ Recipients &rarr;</span></td>';
	my $ccount = 0;

	foreach my $c (@$rx) {
		if ($ccount && ($ccount % $column_block == 0)) {
			printx '<td ', $what_td, '>&nbsp;</td>';
		}
		printx '<td ', $what_td, ' class="beacord ordback"><span title="', beacon_name($c), '">', $ids->{$c}, '</span></td>';
		$ccount++;
	}

	printx "</tr>\n";
}

sub render_matrix {
	my ($start, $step) = @_;

	my $attname = $page->param('att');
	my $atthideinfo = $page->param('hideinfo');
	my $attwhat = $page->param('what');
	my $full_matrix = $page->param('full');
	my $show_lastupdate = $page->param('showlastupdate');

	$attname ||= 'ttl';
	$atthideinfo ||= $default_hideinfo;
	$attwhat ||= $default_what;
	$full_matrix ||= $default_full_matrix;

	my $what_td = '';

	$what_td = 'colspan="2"' if $attwhat eq 'both';

	my $attat = $page->param('at');
	$attat = 0 if not defined $attat or $attat eq '';

	my $addinfo = '';
	if ($attat > 0) {
		$addinfo = " (<a href=\"".$url."what=$attwhat&amp;att=$attname\">Live stats</a>)";
	} elsif ($history_enabled) {
		$addinfo = " (<a href=\"".$url."what=$attwhat&amp;att=$attname&amp;at=" . (time - 60) ."\">Past stats</a>";
		$addinfo .= ", <a href=\"".$url."history=1\">History</a>)";
	}

	start_document($addinfo);

	build_header($attname, $atthideinfo, $attwhat, $full_matrix, $show_lastupdate, $start, $step);

	my $c;
	my $i = 1;
	my @problematic = ();
	my @warmingup = ();
	my @localnoreceive = ();
	my @repnosources = ();
	my @lowrx = ();
	my @rx = ();
	my @tx = ();

	my %ids;

	my @sortedkeys = sort keys %adj;

	foreach $c (@sortedkeys) {
		$ids{$c} = 0;

		$adj{$c}[IN_EDGE] ||= 0;
		$adj{$c}[OUT_EDGE] ||= 0;

		if (defined($adj{$c}[AGE]) and $adj{$c}[AGE] < 30) {
			push (@warmingup, $c);
		} elsif (not $adj{$c}[IN_EDGE] and not $adj{$c}[OUT_EDGE]) {
			push (@problematic, $c);
		} else {

			$ids{$c} = $i;
			$i++;

			if (not $full_matrix) {
				if (not $adj{$c}[IN_EDGE]) {
					if ($adj{$c}[RX_LOCAL] ne 'true') {
						push (@localnoreceive, $c);
					} else {
						push (@repnosources, $c);
					}
				} elsif (($adj{$c}[IN_EDGE] / scalar(@sortedkeys)) <= 0.25) { # and $adj{$c}[IN_EDGE] < 6) {
					push (@lowrx, $c);
				} else {
					push (@rx, $c);
				}

				push (@tx, $c) if $adj{$c}[OUT_EDGE] > 1;
			} else {
				push (@rx, $c);
				push (@tx, $c);
			}
		}
	}

	my $rcount = 0;
	printx '<table border="0" cellspacing="0" cellpadding="0" class="adjr adj">', "\n";

	foreach $b (@tx) {
		$rcount++ % $row_block == 0 && column_header(\@rx, $what_td, \%ids);
		printx '<tr>';
		printx '<td class="beacname">', beacon_name($b), '</td>';
		my $ccount = 0;
		foreach $a (@rx) {
			($ccount++ % $column_block == 0) &&
				printx '<td class="beacord ordback"><span title="', beacon_name($b), '">', $ids{$b}, '</span></td>';
			if ($b ne $a and defined $adj{$a}[NEIGH]{$b}) {
				my $txt = $adj{$a}[NEIGH]{$b}[1]{$attname};
				my $txtssm = $adj{$a}[NEIGH]{$b}[2]{$attname};

				if ($attname ne 'ttl') {
					$txt = sprintf "%.1f", $txt if defined $txt;
					$txtssm = sprintf "%.1f", $txtssm if defined $txtssm;
				}

				if ($attwhat eq 'both') {
					if (not defined $txt and not defined $txtssm) {
						printx '<td ', $what_td, ' class="blackhole">XX</td>';
					} else {
						make_matrix_cell($b, $a, 'asm', $txt, 'historyurl');
						make_matrix_cell($b, $a, 'ssm', $txtssm, 'historyurl');
					}
				} else {
					my $whattype = 'asm';
					my $cssclass = 'AAS';

					my $loss = $adj{$a}[NEIGH]{$b}[1]{'loss'};
					my $ssmloss = $adj{$a}[NEIGH]{$b}[2]{'loss'};

					if ($attwhat eq 'asm') {
						if (not defined $loss) {
							$loss = 100.;
						}
					} elsif ($attwhat eq 'ssm') {
						if (not defined $ssmloss) {
							$loss = 100.;
						} else {
							$loss = $ssmloss;
						}
					} else {
						if (not defined $ssmloss) {
							if (not defined $loss) {
								$loss = 100.;
							}
						} else {
							if (not defined $loss) {
								$loss = $ssmloss;
							} else {
								$loss = ($loss + $ssmloss) / 2.;
							}
						}
					}

					if ($attwhat eq 'ssmorasm') {
						if (defined $txtssm) {
							if (not defined $txt) {
								$cssclass = 'AS';
							}
							$txt = $txtssm;
							$whattype = 'ssm';
						} elsif (defined $txt) {
							$cssclass = 'AA';
						}
					} elsif ($attwhat eq 'ssm') {
						$txt = $txtssm;
					}

					if ($loss > 45.) {
						$cssclass = 'loss';
					} elsif ($loss > 15.) {
						$cssclass = 'someloss';
					}

					if (not defined $txt) {
						printx '<td ', $what_td, ' class="blackhole">XX</td>';
					} else {
						printx '<td class="', $cssclass, '">';
						make_history_link($b, $a, $whattype, $txt, 'historyurl');
						printx '</td>';
					}
				}
			} elsif ($a eq $b) {
				printx '<td ', $what_td, ' class="corner">&nbsp;</td>';
			} elsif ($full_matrix and $adj{$a}[RX_LOCAL] ne 'true') {
				printx '<td ', $what_td, ' class="noreport">N/R</td>';
			} else {
				printx '<td ', $what_td, ' class="blackhole">XX</td>';
			}
		}
		printx '</tr>', "\n";
	}
	printx '</table>', "\n";

	printx '<br />', "\n";

	printx '<table border="0" cellspacing="0" cellpadding="0" class="adjr adj"><tr>', "\n";
	printx '<td><b>Matrix cell colors:</b></td>', "\n";
	printx '<td>Full connectivity (ASM and SSM)</td><td class="AAS">X</td>', "\n";
	printx '<td>ASM only</td><td class="AA">X</td>', "\n";
	printx '<td>SSM only</td><td class="AS">X</td>', "\n";
	printx '<td>Loss > 15%</td><td class="someloss">X</td>', "\n";
	printx '<td>Loss > 45%</td><td class="loss">X</td>', "\n";
	printx '</tr></table>', "\n";

	if (scalar(@repnosources) > 0) {
		printx '<h4 style="margin-bottom: 0">Beacons that report no received sources';
		do_faq_qlink('nosources');
		printx '</h4>', "\n";
		printx '<ul>', "\n";
		foreach $a (@repnosources) {
			printx '<li>', print_beacord_name($ids{$a}, $a);
			printx ' (', obsf_email($adj{$a}[CONTACT]), ')' if $adj{$a}[CONTACT];
			printx '</li>', "\n";
		}
		printx '</ul>', "\n";
	}

	if (scalar(@lowrx) > 0) {
		printx '<h4 style="margin-bottom: 0">Beacons that report only a small number of received sources';
		do_faq_qlink('lowsources');
		printx '</h4>', "\n";
		printx '<ul>', "\n";
		foreach $a (@lowrx) {
			printx '<li>', print_beacord_name($ids{$a}, $a);

			printx ' <small>Receives</small> { ';

			my $first = 1;

			foreach $b (keys %{$adj{$a}[NEIGH]}) {
				printx ', ' if not $first;
				$first = 0;
				if ($ids{$b}) {
					printx print_beacord_name($ids{$b}, $b);
				} else {
					printx '<span class="beacon">', $b;
					printx ' (', $adj{$b}[NAME], ')' if $adj{$b}[NAME];
					printx '</span>';
				}
			}

			printx ' }';

			printx '</li>', "\n";
		}
		printx '</ul>', "\n";
	}

	if (scalar(@localnoreceive) > 0) {
		printx '<h4 style="margin-bottom: 0">Beacons not received localy';
		do_faq_qlink('localonly');
		printx '</h4>', "\n";
		printx '<ul>', "\n";
		foreach $a (@localnoreceive) {
			printx '<li>', print_beacord_name($ids{$a}, $a);
			printx ' (', obsf_email($adj{$a}[CONTACT]), ')' if $adj{$a}[CONTACT];
			printx '</li>', "\n";
		}
		printx '</ul>', "\n";
	}

	if (scalar(@warmingup) > 0) {
		printx '<h4>Beacons warming up (age < 30 secs)';
		do_faq_qlink('warmingup');
		printx '</h4>', "\n";
		printx '<ul>', "\n";
		foreach $a (@warmingup) {
			printx '<li>', $a;
			printx ' (', $adj{$a}[NAME], ', ', obsf_email($adj{$a}[CONTACT]), ')' if $adj{$a}[NAME];
			printx '</li>', "\n";
		}
		printx '</ul>', "\n";
	}

	if (scalar(@problematic) ne 0) {
		printx '<h4>Beacons with no connectivity</h4>', "\n";
		printx '<ul>', "\n";
		my $len = scalar(@problematic);
		for (my $j = 0; $j < $len; $j++) {
			my $prob = $problematic[$j];
			my @neighs = keys %{$adj{$prob}[NEIGH]};

			printx '<li>', $prob;
			if ($adj{$prob}[NAME]) {
				printx ' (', $adj{$prob}[NAME];
				printx ', ', obsf_email($adj{$prob}[CONTACT]) if $adj{$prob}[CONTACT];
				printx ')';
			}

			my $ned = scalar(@neighs);
			my $k = $ned;
			if ($k > 3) {
				$k = 3;
			}

			if ($ned) {
				printx '<ul>Received from:<ul>', "\n";

				for (my $l = 0; $l < $k; $l++) {
					printx '<li><span class="beacon">', $neighs[$l];
					printx ' (', $adj{$neighs[$l]}[NAME], ')' if $adj{$neighs[$l]}[NAME];
					printx '</span></li>', "\n";
				}

				printx '<li>and others</li>', "\n" if $k < $ned;

				printx '</ul></ul>';
			}

			printx '</li>', "\n";
		}
		printx '</ul>', "\n";
	}

	if (not $atthideinfo) {
		printx '<br />', "\n";
		printx '<table border="0" cellspacing="0" cellpadding="0" class="adjr" id="adjname">', "\n";

		printx '<tr class="tablehead"><td /><td /><td /><td>Age</td><td>Source Address</td>';
		printx '<td>Admin Contact</td><td>';
		do_faq_link('L/M', 'lg_matrix');
		printx '</td><td><a href="', $ssm_ping_url, '">SSM P</a>';
		printx '</td></tr>', "\n";
		foreach $a (@sortedkeys) {
			if ($ids{$a} > 0) {
				printx '<tr>', '<td class="beacname">';
				printx '<a class="beacon_url" href="', $adj{$a}[URL], '">' if $adj{$a}[URL];
				printx beacon_short_name($a);
				printx '</a>' if $adj{$a}[URL];
				printx '</td>';
				printx '<td>', print_beacord($ids{$a}), '</td>';

				printx '<td>';
				if ($flag_url_format ne '' and $adj{$a}[COUNTRY]) {
					printx make_flag_url($adj{$a}[COUNTRY]);
				}
				printx '</td>';

				printx '<td class="age">', format_date($adj{$a}[AGE]), '</td>';
				# Removing port number from id and link toward RIPE whois db
			        my $ip = $a;
			        $ip =~ s/\/\d+$//;
			        printx '<td class="addr"><a href="', make_ripe_search_url($ip), '">', $ip, '</a></td>';
				printx '<td class="admincontact">', obsf_email($adj{$a}[CONTACT]), '</td>';

				my $urls;
				$urls .= " <a href=\"" . $adj{$a}[LG] . "\">L</a>" if $adj{$a}[LG];
				$urls .= " /" if $adj{$a}[LG] and $adj{$a}[MATRIX];
				$urls .= " <a href=\"" . $adj{$a}[MATRIX] . "\">M</a>" if $adj{$a}[MATRIX];

				printx '<td class="urls">', ($urls or '-'), '</td>';

				printx '<td class="infocol">';
				if ($adj{$a}[SSM_PING]) {
					printx '&bull;';
				} else {
					printx '&nbsp;';
				}
				printx '</td>';

				printx '</tr>', "\n";
			}
		}
		printx '</table>', "\n";
	}

	printx '<p><i>If you wish to run a beacon in your site check <a href="http://dbeacon.innerghost.net/Running_dbeacon">Running dbeacon</a> at <a href="http://dbeacon.innerghost.net">dbeacon\'s Wiki</a>.</i></p>';

	end_document;
}

sub update_ttl_hist {
	my ($file, $ttl) = @_;

	my @lines = ();

	if (open F, "< $file") {
		while (<F>) {
			push @lines, $_;
		}

		close F;
	}

	open F, "> $file";

	print F 'At ', time, ' \'' . localtime() . '\' TTL was ', $ttl, "\n";

	if (scalar(@lines) > 0) {
		my $i = 1;

		if ($lines[0] =~ m/^At (\d+) '.*' TTL was (\d+)$/) {
			if ($2 != $ttl) {
				$i = 0;
			}
		}

		for (; $i < scalar(@lines); $i++) {
			print F $lines[$i];
		}
	}

	close F;
}

sub store_meta_data {
	my ($dirn, $name, $data) = @_;

	if (defined $data) {
		if (open FILE, "> $dirn/$name") {
			print FILE $data;
			close FILE;
		}
	}
}

sub store_data {
	die "Outdated dumpfile\n" if check_outdated_dump;

	parse_dump_file(@_);

	foreach my $a (keys %adj) {
		if ($adj{$a}[NAME] and
			(not defined $histbeacmatch or ($adj{$a}[NAME] =~ m/$histbeacmatch/))) {

			my $dstbeacon = build_host($adj{$a}[NAME], $a);
			my $dirn = hist_beacon_dir $dstbeacon;
			if (not -d $dirn) {
				mkdir $dirn;
			}

			store_meta_data $dirn, 'lastupdate', time;
			store_meta_data $dirn, 'contact', $adj{$a}[CONTACT];
			store_meta_data $dirn, 'country', $adj{$a}[COUNTRY];
			store_meta_data $dirn, 'website', $adj{$a}[URL];
			store_meta_data $dirn, 'matrix_url', $adj{$a}[MATRIX];
			store_meta_data $dirn, 'lg_url', $adj{$a}[LG];

			foreach my $b (keys %adj) {
				if ($a ne $b and defined $adj{$a}[NEIGH]{$b}) {
					if ($adj{$b}[NAME]) {
						store_data_one($a, $adj{$a}[NAME], $b, $adj{$b}[NAME], "asm");
						store_data_one($a, $adj{$a}[NAME], $b, $adj{$b}[NAME], "ssm");
					}
				}
			}
		}
	}

	return 0;
}

sub store_data_one {
	my ($dst, $dstname, $src, $srcname, $tag) = @_;

	my $dst_h = build_host($dstname, $dst);
	my $src_h = build_host($srcname, $src);

	my %values;

	my $good = 0;

	my $index = 1;
	if ($tag eq 'ssm') {
		$index = 2;
	}

	update_ttl_hist(build_history_file_path($dst_h, $src_h) . "/$tag-ttl-hist",
		$adj{$dst}[NEIGH]{$src}[$index]{'ttl'}) if defined $adj{$dst}[NEIGH]{$src}[$index]{'ttl'};

	foreach my $type ("ttl","loss","delay","jitter") {
		$values{$type} = $adj{$dst}[NEIGH]{$src}[$index]{$type};
		$good++ if defined $values{$type};
	}

	if ($good > 0) {
		storedata($dst_h, $src_h, $tag, %values);
	}
}

sub build_host {
	my ($name, $addr) = @_;

	# Removing port number as it change between two beacon restarts
        $addr =~ s/\/\d+$//;

	# Removing bad chars in name
        $name =~ s/[^A-z0-9\:\.\-_\s]//g;

	return "$name-$addr";
}

sub make_hist_file_path {
	my ($dstbeacon, $srcbeacon) = @_;

	mkdir $historydir;
	mkdir "$historydir/$dstbeacon";
	mkdir "$historydir/$dstbeacon/sources";
	mkdir "$historydir/$dstbeacon/sources/$srcbeacon";

	return 1;
}

sub build_history_file_path {
	my ($dstbeacon, $srcbeacon) = @_;

	$srcbeacon =~ s/\.(ssm|asm)$//;

	make_hist_file_path($dstbeacon, $srcbeacon);

	return "$historydir/$dstbeacon/sources/$srcbeacon";
}

sub build_rrd_file_path {
	my ($dstbeacon, $srcbeacon, $asmorssm) = @_;

	return build_history_file_path($dstbeacon, $srcbeacon) . "/$asmorssm-hist.rrd";
}

sub check_rrd {
	my ($dstbeacon, $srcbeacon, $asmorssm) = @_;

	my $rrdfile = build_rrd_file_path(@_);

	if (! -f $rrdfile) {
		if ($verbose) {
			print "New combination: RRD file $rrdfile needs to be created\n";
		}

		if (!$RRDs::{create}($rrdfile,
			'-s 60',			# steps in seconds
			'DS:ttl:GAUGE:90:0:255',	# 90 seconds befor reporting it as unknown
			'DS:loss:GAUGE:90:0:100',	# 0 to 100%
			'DS:delay:GAUGE:90:0:U',	# Unknown max for delay
			'DS:jitter:GAUGE:90:0:U',	# Unknown max for jitter
			'RRA:MIN:0.5:1:1440',		# Keeping 24 hours at high resolution
			'RRA:MIN:0.5:5:2016',		# Keeping 7 days at 5 min resolution
			'RRA:MIN:0.5:30:1440',		# Keeping 30 days at 30 min resolution
			'RRA:MIN:0.5:120:8784',		# Keeping one year at 2 hours resolution
			'RRA:AVERAGE:0.5:1:1440',
			'RRA:AVERAGE:0.5:5:2016',
			'RRA:AVERAGE:0.5:30:1440',
			'RRA:AVERAGE:0.5:120:8784',
			'RRA:MAX:0.5:1:1440',
			'RRA:MAX:0.5:5:2016',
			'RRA:MAX:0.5:30:1440',
			'RRA:MAX:0.5:120:8784')) {
			return 0;
		}
	}

	return $rrdfile;
}

sub storedata {
	my ($dstbeacon, $srcbeacon, $asmorssm, %values) = @_;

	my $rrdfile = check_rrd($dstbeacon, $srcbeacon, $asmorssm);

	# Update rrd with new values

	my $updatestring = 'N';
	foreach my $valuetype ("ttl","loss","delay","jitter") {
		# Store it in s and not ms
		$values{$valuetype} = $values{$valuetype} / 1000. if $valuetype eq 'delay' or $valuetype eq 'jitter';
		$updatestring .= ':' . $values{$valuetype};
	}

	print "Updating $dstbeacon <- $srcbeacon with $updatestring\n" if $verbose > 1;

	open F2, '> ' . build_history_file_path($dstbeacon, $srcbeacon) . '/lastupdate';
	print F2 time;
	close F2;

	return $RRDs::{update}($rrdfile, $updatestring);
}

sub graphgen {
	my $title;
	my $ytitle;
	my $unit;

	if ($type eq 'ttl') { $title = 'TTL'; $ytitle = 'Hops'; $unit = '%3.0lf hops' }
	elsif ($type eq 'loss') { $title = 'Loss'; $ytitle = '% of packet loss'; $unit = '%2.1lf %%' }
	elsif ($type eq 'delay') { $title = 'Delay'; $ytitle = 'Seconds'; $unit = '%2.2lf %ss' }
	elsif ($type eq 'jitter') { $title = 'Jitter'; $ytitle = 'Seconds'; $unit = '%2.2lf %ss' }
	else { die "Unknown type\n"; }

	# Display only the name
	my ($msrc, undef, $asmorssm) = get_name_from_host($src);
	my ($mdst) = get_name_from_host($dst);

	my $rrdfile = build_rrd_file_path($dst, $src, $asmorssm);

	# Escape ':' chars
	$rrdfile =~ s/:/\\:/g;

	$asmorssm =~ s/([a-z])/\u$1/g; # Convert to uppercase

	print $page->header(-type => 'image/png', -expires => '+3s');

	my $width = 450;
	my $height = 150;

	if (defined $page->param('thumb')) {
		$width = 300;
		$height = 100;
		$title .= " ($ytitle)";
	} else {
		$title.= " from $msrc to $mdst ($asmorssm)";
	}

	my @args = ('-',
		'--imgformat', 'PNG',
		'--start', $age,
		"--width=$width",
		"--height=$height",
		"--title=$title",
		"DEF:Max=$rrdfile:$type:MAX",
		"DEF:Avg=$rrdfile:$type:AVERAGE",
		"DEF:Min=$rrdfile:$type:MIN",
		'CDEF:nodata=Max,UN,INF,UNKN,IF',
		'AREA:nodata#E0E0FD');

	if (not defined $page->param('thumb')) {
		push (@args, '--vertical-label',$ytitle);
		push (@args, 'COMMENT:'.strftime("%a %b %e %Y %H\\:%M (%Z)", localtime).' '.strftime("%H\\:%M (GMT)", gmtime).'\r');
		push (@args, 'AREA:Max#FF0000:Max');
		push (@args, 'GPRINT:Max:MAX:'.$unit);
		push (@args, 'AREA:Avg#CC0000:Avg');
		push (@args, 'GPRINT:Avg:AVERAGE:'.$unit);
		push (@args, 'AREA:Min#990000:Min');
		push (@args, 'GPRINT:Min:MIN:'.$unit);
	} else {
		push (@args, 'AREA:Avg#CC0000:Avg');
		push (@args, 'GPRINT:Avg:AVERAGE:'.$unit);
	}

	push (@args, 'GPRINT:Max:LAST:Last '.$unit.'\n');

	if (!$RRDs::{graph}(@args)) {
		die($RRDs::{error});
	}
}

sub get_beacon_metadata_one {
	my ($dirn, $name) = @_;

	my $res = undef;

	if (open FILE, "< $dirn/$name") {
		$res = readline FILE;
		close FILE;
	}

	return $res;
}

sub get_beacon_metadata {
	my ($dst) = @_;

	my $dirn = "$historydir/$dst";

	my $lastupdate = get_beacon_metadata_one $dirn, 'lastupdate';
	my $contact = get_beacon_metadata_one $dirn, 'contact';
	my $country = get_beacon_metadata_one $dirn, 'country';
	my $website = get_beacon_metadata_one $dirn, 'website';
	my $matrix = get_beacon_metadata_one $dirn, 'matrix_url';
	my $lg = get_beacon_metadata_one $dirn, 'lg_url';

	return [$lastupdate, $contact, $country, $website, $matrix, $lg];
}

sub get_beacons {
	return () if not opendir DIR, $historydir;

	my @res = ();

	foreach my $dirc (readdir(DIR)) {
		my $t = $historydir . '/' . $dirc;
		if (-d $t) {
			if ($dirc ne '.' and $dirc ne '..') {
				my $metadata = get_beacon_metadata $dirc;

				push (@res, [$dirc, $t, $metadata->[0], $metadata->[1], $metadata->[2], $metadata->[3], $metadata->[4], $metadata->[5]]);
			}
		}
	}

	closedir DIR;

	return @res;
}

sub get_sources {
	my ($dst) = @_;

	my $targ = hist_beacon_sources_dir $dst;

	return () if not opendir DIR, $targ;

	my @res = ();

	foreach my $item (readdir(DIR)) {
		my $t = "$targ/$item";
		if ($item ne '.' and $item ne '..' and -d $t and -f "$t/lastupdate") {
			my ($name, $addr) = get_name_from_host($item);
			my $tm = (stat("$t/lastupdate"))[9];

			my $asmhist = "$t/asm-hist.rrd";
			my $ssmhist = "$t/ssm-hist.rrd";

			if (not -f $asmhist) {
				$asmhist = undef;
			}

			if (not -f $ssmhist) {
				$ssmhist = undef;
			}

			my $metadata = get_beacon_metadata $item;

			push @res, [$item, $t, $tm, $name, $addr, $asmhist, $ssmhist, $metadata->[2]];
		}
	}

	closedir DIR;

	return @res;
}

sub get_name_from_host {
	my ($host) = @_;

	return ($1, $2, $3) if $host =~ /^(.+)\-(.+)\.(ssm|asm)$/;
	return ($1, $2) if $host =~ /^(.+)\-(.+)$/;

	return 0;
}

sub do_list_beacs {
	my ($name, $dst, $src, @vals) = @_;

	printx '<select name="', $name, '" onchange="location = this.options[this.selectedIndex].value;">', "\n";

	my $def = $name eq 'srcc' ? $src : $dst;

	foreach my $bar (@vals) {
		my $foo = $bar->[0];
		printx '<option value="'.$url.'history=1&amp;dst=';
		printx $dst, '&amp;src=' if $name eq 'srcc';
		printx $foo;
		printx '"';

		printx ' selected="selected"' if $foo eq $def;

		printx ">" . (get_name_from_host($foo))[0];
		printx ' (' . (get_name_from_host($foo))[2] . ')' if $name eq 'srcc';
		printx '</option>', "\n";
	}

	printx '</select>', "\n";
}

sub do_list_sources_one {
	my ($dst, $src, $name, $tag, $def) = @_;

	printx '<option value="', make_history_url($dst, $src, $tag), '"';
	printx ' selected="selected"' if "$src.$tag" eq $def;
	printx '>', $name, ' (', $tag, ')</option>';
}

sub do_list_sources {
	my ($name, $dst, $src, @vals) = @_;

	printx '<select name="', $name, '" onchange="location = this.options[this.selectedIndex].value;">', "\n";

	foreach my $bar (@vals) {
		do_list_sources_one $dst, $bar->[0], $bar->[3], 'asm', $src if defined $bar->[5];
		do_list_sources_one $dst, $bar->[0], $bar->[3], 'ssm', $src if defined $bar->[6];
	}

	printx '</select>', "\n";
}

sub graphthumb {
	my ($type) = shift;
	printx '<a href="' . full_url0 . "&amp;history=1&amp;type=$type\">\n";
	printx '<img style="margin-right: 0.5em; margin-bottom: 0.5em; border: 0" alt="thumb" src="' . full_url0 . "&amp;type=$type&amp;img=true&amp;thumb=true&amp;age=$age\" /></a><br />\n";
}

sub list_graph {
	start_document(" (<a href=\"$url\">Live stats</a>)");

	if (defined $dst) {
		printx '<p>To ';

		do_list_beacs("dstc", $dst, undef, get_beacons());

               if (defined $src) {
                       printx "From ";
		       do_list_sources('srcc', $dst, $src, get_sources($dst));

                       if (defined $type) {
                               printx "Type ";

                               my @types = (["-- All --", "", ""],
						["TTL", "ttl", ""],
						["Loss", "loss", ""],
						["Delay", "delay", ""],
						["Jitter", "jitter", ""]);

				printx '<select name="type" onchange="location = this.options[this.selectedIndex].value;">'."\n";

				foreach my $foo (@types) {
					printx '<option value="' . full_url0 . '&amp;history=1&amp;type=' . $$foo[1].'"';
					printx ' selected="selected"' if $type eq $$foo[1];
					printx '>'.$$foo[0]."\n";;
				}
				printx "</select>\n";
			}
		}

		printx "</p>";
	}

	if (not defined $dst) {

		# List beacon receiving infos

		printx '<p>Select a receiver:</p>';

		my @beacs = get_beacons();

		my $now = time;
		my @wking = ();
		my @old = ();

		for (my $i = 0; $i < scalar(@beacs); $i++) {
			if (($now - $beacs[$i]->[2]) > 900) {
				push @old, $i;
			} else {
				push @wking, $i;
			}
		}

		@wking = sort { $beacs[$b]->[2] <=> $beacs[$a]->[2] } @wking;
		@old = sort { $beacs[$b]->[2] <=> $beacs[$a]->[2] } @old;

		printx '<h3 style="margin: 0">Active (', scalar(@wking), ')</h3>';

		printx '<ul class="beaconlist">', "\n";

		foreach my $bar (@wking) {
			my $beac = $beacs[$bar]->[0];
			printx '<li>';

			printx make_flag_url($beacs[$bar]->[4]), '&nbsp;' if defined $beacs[$bar]->[4];

			printx '<a href="', $url, 'history=1&amp;dst=', $beac, '"';
			printx ' title="', (get_name_from_host($beac))[1], '"';
			printx '>' . (get_name_from_host($beac))[0];
			printx '</a>';

			if (defined $beacs[$bar]->[3]) {
				printx ' <i>(', $beacs[$bar]->[3], ')</i>';
			}

			# my $tm = $beacs[$bar]->[2];
			# printx ' <small>[Last update ',
			#	format_date(time - $tm), ' ago]</small>';

			printx '</li>', "\n";
		}

		printx "</ul>\n";

		if (scalar(@old)) {
			printx '<h3 style="margin: 0">Inactive (', scalar(@old), ')</h3>';

			printx '<ul class="beaconlist">', "\n";

			foreach my $bar (@old) {
				my $beac = $beacs[$bar]->[0];
				printx '<li>';
				printx make_flag_url($beacs[$bar]->[4]), '&nbsp;' if defined $beacs[$bar]->[4];
				printx '<a href="', $url, 'history=1&amp;dst=', $beac, '"';
				printx ' title="', (get_name_from_host($beac))[1], '"';
				printx '>' . (get_name_from_host($beac))[0];
				printx '</a>';

				my $tm = $beacs[$bar]->[2];

				printx ' <small>[Last update ',
					format_date(time - $tm), ' ago]</small>';

				printx '</li>', "\n";
			}

			printx "</ul>\n";
		}

	} elsif (not defined $src) {
		printx '<br />Select a source:';

		# List visible src for this beacon

		my @beacs = get_sources($dst);

		printx '<ul class="beaconlist">', "\n";
		foreach my $beac (@beacs) {
			printx '<li>', "\n";

			printx make_flag_url($beac->[7]), '&nbsp;' if defined $beac->[7];

			if (defined $beac->[5]) {
				printx '<a href="', make_history_url($dst, $beac->[0], 'asm'), '">';
			}

			printx $beac->[3];

			if (defined $beac->[5]) {
				printx '</a>'
			}

			if (defined $beac->[6]) {
				printx ' / <a href="', make_history_url($dst, $beac->[0], 'ssm'), '">SSM</a>';
			}

			printx ' <small>[Last update ', format_date(time - $beac->[2]),
					' ago]</small>';

			printx '</li>', "\n";
		}
		printx '</ul>', "\n";
	}  elsif (not defined $type) {
		printx "<div style=\"margin-left: 2em\">\n";
		printx "<h2 style=\"margin-bottom: 0\">History for the last " . $ages{$age} . "</h2>\n";
		printx "<small>Click on a graphic for more detail</small><br />\n";
		printx "<table style=\"margin-top: 0.6em\">";

		my $count = 0;

		foreach my $type ("ttl","loss","delay","jitter") {
			printx '<tr>' if ($count % 2) == 0;
			printx '<td>';
			graphthumb($type);
			printx '</td>', "\n";
			printx '</tr>', "\n" if ($count %2) == 1;
			$count++;
		}

		printx "</table>\n";

		printx '<p>Last: ';

		foreach my $agen (@propersortedages) {
			printx " <a href=\"" . full_url0 . "&amp;history=1&amp;age=" . $agen . "\">" . $ages{$agen} . "</a>";
		}

		printx "</p>\n";
		printx "</div>\n";
	} else {
		printx "<br />";
		printx "<div style=\"margin-left: 2em\">\n";
		# Dst, src and type selected => Displaying all time range graphs
		foreach my $age ('-1d','-1w','-1m','-1y') {
			printx "<img style=\"margin-bottom: 0.5em\" src=\"" . full_url . "&amp;age=$age&amp;img=true\" /><br />";
		}
		printx "</div>";
	}

	end_document;
}

sub start_base_document {
	printx "<?xml version=\"1.0\"?>\n";
	printx "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Strict//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd\">\n";
	printx "<html xmlns=\"http://www.w3.org/1999/xhtml\" lang=\"en\" xml:lang=\"en\">\n";

	printx "<head>
	<title>$page_title</title>
	<meta http-equiv=\"refresh\" content=\"60\" />\n";

	if ($css_file) {
		printx "\t<link rel=\"stylesheet\" text=\"text/css\" href=\"$css_file\" />\n";
	} else {
		print_default_style();
	}

	printx "</head>\n<body>\n";
}

sub print_default_style() {
	printx "\t<style type=\"text/css\">
body {
	font-family: Verdana, Arial, Helvetica, sans-serif;
	font-size: 100%;
}

table.adjr {
	text-align: center;
}
table.adjr td.beacname {
	text-align: right;
}
table.adjr td {
	padding: 3px;
	border-bottom: 0.1em solid white;
}
table.adj td.AAS, table.adj td.A_asm, table.adj td.A_ssm {
	background-color: #99ff99;
}

table.adj td.AA {
	/* background-color: #c0ffc0; */
	background-color: #ccffcc;
}

table.adj td.AS {
	/* background-color: #96d396; */
	/* background-color: #99cccc; */
	background-color: #ccff66;
}

table.adj td.noreport {
	background-color: #ccc;
}

table.adj td.blackhole {
	background-color: #000000;
}

table.adj td.corner {
/*	background-color: #dddddd; */
	background-color: white;
}

table.adj td.loss {
	background-color: red;
}

table.adj td.someloss {
	background-color: orange;
}

table.adj td.A_asm {
	border-right: 0.075em solid white;
}

table.adj td.noreport, td.blackhole, td.AAS, td.AS, td.AA, td.A_ssm, td.corner, td.loss, td.someloss, td.beacord {
	border-right: 0.2em solid white;
}

table#adjname td.addr, table#adjname td.admincontact, table#adjname td.age, table#adjname td.urls, td.infocol {
	background-color: #eeeeee;
	border-right: 0.2em solid white;
}
table#adjname td.age {
	font-size: 80%;
}

.tablehead {
	font-weight: bold;
}

.beacord {
	font-weight: bold;
}

.ordback {
	background-color: #cee7ff;
}

.addr, .admincontact {
	font-size: 80%;
}

.addr a, .addr a:visited {
	text-decoration: none;
	color: black;
}

.beacon {
	font-style: italic;
}

ul#view {
	margin: 0;
	padding: 0;
}

ul#view li {
	display: inline;
	padding: 0;
	padding-left: 5px;
	margin: 0;
}

ul.beaconlist {
	padding-left: 1em;
	list-style-type: none;
	margin-top: 0.5em;
}

ul.beaconlist > li {
	margin: 0.3em;
}

#view #currentview {
	border-bottom: 1px solid #d4d4d4;
}

a {
	color: Blue;
	border-bottom: 1px solid #b0b0b0;
	text-decoration: none;
}

a:visited {
	color: Blue;
	border-bottom: 1px solid #b0b0b0;
	text-decoration: none;
}

a:hover {
	border-bottom: 1px solid Blue;
	text-decoration: none;
}

a.historyurl, a.historyurl:visited {
	color: black;
	text-decoration: none;
	border: 0;
}

\t</style>";
}

