use strict;
use warnings;
use Irssi;
use POSIX ();
use JSON::PP ();
use Cwd ();
use File::Basename ();

# Directory holding render_image.sh / viewer.sh. Defaults to this script's own
# real location (resolving the irssi autorun symlink) so the repo is portable.
my $SCRIPT_DIR = eval {
    File::Basename::dirname(Cwd::abs_path(__FILE__));
} || "$ENV{HOME}/github/irssi-wezterm-images";

our $VERSION = '0.4';
our %IRSSI = (
    authors     => 'pduvall',
    name        => 'wezterm_img',
    description => 'Show small/faded/pixelated previews of images and webpage links (embedded image or screenshot) in a dedicated WezTerm side pane.',
    license     => 'MIT',
);

# ---------------------------------------------------------------------------
# Settings (medium-style defaults). Change live with /set <name> <value>.
# ---------------------------------------------------------------------------
Irssi::settings_add_bool('wezterm_img', 'wezterm_img_enabled',     1);
Irssi::settings_add_bool('wezterm_img', 'wezterm_img_sites',       1);
Irssi::settings_add_int ('wezterm_img', 'wezterm_img_width_cells', 20);
Irssi::settings_add_int ('wezterm_img', 'wezterm_img_pane_buffer', 3);
Irssi::settings_add_int ('wezterm_img', 'wezterm_img_colorize_pct',20);
Irssi::settings_add_int ('wezterm_img', 'wezterm_img_saturation',  55);
Irssi::settings_add_int ('wezterm_img', 'wezterm_img_pixel_pct',   20);
Irssi::settings_add_int ('wezterm_img', 'wezterm_img_max_mb',      10);
Irssi::settings_add_str ('wezterm_img', 'wezterm_img_channels',    '');
Irssi::settings_add_str ('wezterm_img', 'wezterm_img_helper_dir',  $SCRIPT_DIR);
# auto|local|remote|off. auto = local when inside WezTerm, else inactive.
# Set 'remote' when irssi runs over ssh/mosh and a local watch_remote.sh bridges back.
Irssi::settings_add_str ('wezterm_img', 'wezterm_img_mode',        'auto');
# remote mode: file image URLs are appended to. '' => $HOME/.irssi-wezterm-img.queue
Irssi::settings_add_str ('wezterm_img', 'wezterm_img_queue_file',  '');

# cached viewer pane id + a small LRU of recently-seen URLs (dedupe)
my $VIEWER_PANE;
my @SEEN;
my %SEEN_SET;
use constant SEEN_MAX => 200;

sub state_dir {
    my $d = ($ENV{TMPDIR} || '/tmp');
    $d =~ s{/$}{};
    return "$d/irssi-wezterm-img";
}

sub seen_recently {
    my ($url) = @_;
    return 1 if $SEEN_SET{$url};
    push @SEEN, $url;
    $SEEN_SET{$url} = 1;
    if (@SEEN > SEEN_MAX) {
        my $old = shift @SEEN;
        delete $SEEN_SET{$old};
    }
    return 0;
}

sub extract_image_urls {
    my ($msg) = @_;
    my @urls;
    while ($msg =~ m{(https?://[^\s<>"']+?\.(?:png|jpe?g|gif|webp))(?:[?\#][^\s<>"']*)?}gi) {
        push @urls, $1;
    }
    return @urls;
}

# All http(s) URLs that are NOT direct images (those go through the image path).
sub extract_page_urls {
    my ($msg) = @_;
    my @urls;
    while ($msg =~ m{(https?://[^\s<>"']+)}gi) {
        my $u = $1;
        $u =~ s/[.,;:!?)\]}>'"]+$//;              # strip trailing punctuation
        next if $u =~ m{\.(?:png|jpe?g|gif|webp)(?:[?\#]|$)}i;  # image → other path
        push @urls, $u;
    }
    return @urls;
}

# Resolve effective mode. 'auto' => 'local' inside WezTerm, else 'inactive'.
sub effective_mode {
    my $m = lc(Irssi::settings_get_str('wezterm_img_mode') || 'auto');
    return 'off'      if $m eq 'off';
    return $m         if $m eq 'local' || $m eq 'remote';
    return $ENV{WEZTERM_PANE} ? 'local' : 'inactive';   # auto
}

sub queue_file {
    my $f = Irssi::settings_get_str('wezterm_img_queue_file');
    $f = "$ENV{HOME}/.irssi-wezterm-img.queue" unless defined $f && $f =~ /\S/;
    return $f;
}

# remote mode: append a "TYPE\tURL" line; a local watcher renders/dispatches it.
# TYPE is img | site | close. (A bare URL with no tab is treated as img.)
sub enqueue_item {
    my ($type, $url) = @_;
    my $f = queue_file();
    if (open my $fh, '>>', $f) {
        print $fh "$type\t$url\n";
        close $fh;
    }
}

# Tri-state: 1 = pane present, 0 = genuinely absent, -1 = couldn't tell
# (wezterm cli list failed or returned junk). Callers must not treat -1 as
# absent — doing so causes spurious respawns during the brief races around
# split-pane / send-text.
sub pane_alive {
    my ($id) = @_;
    return 0 unless defined $id && $id =~ /^\d+$/;
    my $json = `wezterm cli list --format json 2>/dev/null`;
    return -1 unless defined $json && length $json;
    my $data = eval { JSON::PP::decode_json($json) };
    return -1 unless ref $data eq 'ARRAY';
    for my $p (@$data) {
        return 1 if defined $p->{pane_id} && $p->{pane_id} eq $id;
    }
    return 0;
}

# Ensure the dedicated side pane exists; (re)spawn it if needed. Returns id or undef.
sub ensure_viewer {
    my $helper  = Irssi::settings_get_str('wezterm_img_helper_dir');
    my $width   = Irssi::settings_get_int('wezterm_img_width_cells')  || 20;
    my $buffer  = Irssi::settings_get_int('wezterm_img_pane_buffer');
    my $cells   = $width + $buffer;

    # keep the cached pane if it's present (1) or we can't tell (-1); only a
    # definite 0 means it's gone.
    return $VIEWER_PANE if defined $VIEWER_PANE && pane_alive($VIEWER_PANE) != 0;

    my $statef = state_dir() . '/pane';
    if (open my $fh, '<', $statef) {
        my $id = <$fh>; close $fh;
        chomp $id if defined $id;
        if (defined $id && pane_alive($id) != 0) { return $VIEWER_PANE = $id; }
    }

    my $self = $ENV{WEZTERM_PANE};
    return undef unless defined $self;

    my $id = `wezterm cli split-pane --right --cells $cells --pane-id $self -- bash "$helper/viewer.sh" $width 2>/dev/null`;
    chomp $id if defined $id;
    return undef unless defined $id && $id =~ /^\d+$/;

    $VIEWER_PANE = $id;
    if (open my $fh, '>', $statef) { print $fh $id, "\n"; close $fh; }
    # return focus to irssi so typing isn't interrupted
    system("wezterm cli activate-pane --pane-id $self >/dev/null 2>&1");
    return $VIEWER_PANE;
}

# fork the slow download/screenshot+convert so irssi's event loop never blocks.
# $kind is 'img' (default) or 'site'.
sub spawn_worker {
    my ($url, $pane, $kind) = @_;
    $kind ||= 'img';
    my $helper   = Irssi::settings_get_str('wezterm_img_helper_dir');
    my $width    = Irssi::settings_get_int('wezterm_img_width_cells')  || 20;
    my $colorize = Irssi::settings_get_int('wezterm_img_colorize_pct');
    my $sat      = Irssi::settings_get_int('wezterm_img_saturation');
    my $pix      = Irssi::settings_get_int('wezterm_img_pixel_pct')    || 20;
    my $maxmb    = Irssi::settings_get_int('wezterm_img_max_mb')       || 10;
    my $script   = $kind eq 'site' ? 'render_site.sh' : 'render_image.sh';

    my $pid = fork();
    return unless defined $pid;
    if ($pid == 0) {
        # child; exec only returns if it failed to launch
        exec('bash', "$helper/$script",
             $url, $pane, $width, $colorize, $sat, $pix, $maxmb)
            or POSIX::_exit(1);
    }
    Irssi::pidwait_add($pid);   # reap without blocking
}

sub target_allowed {
    my ($target) = @_;
    my $list = Irssi::settings_get_str('wezterm_img_channels');
    return 1 if !defined $list || $list !~ /\S/;   # empty = all
    return 1 unless defined $target;
    for my $t (split /\s+/, $list) {
        return 1 if lc($t) eq lc($target);
    }
    return 0;
}

sub handle_text {
    my ($msg, $target) = @_;
    return unless Irssi::settings_get_bool('wezterm_img_enabled');
    my $mode = effective_mode();
    return if $mode eq 'off' || $mode eq 'inactive';
    return unless target_allowed($target);

    # [kind => url] pairs, images first.
    my @items = map { ['img', $_] } extract_image_urls($msg);
    if (Irssi::settings_get_bool('wezterm_img_sites')) {
        push @items, map { ['site', $_] } extract_page_urls($msg);
    }
    return unless @items;

    if ($mode eq 'remote') {
        for my $it (@items) {
            next if seen_recently($it->[1]);
            enqueue_item($it->[0], $it->[1]);
        }
        return;
    }

    # local
    my $pane = ensure_viewer() or return;
    for my $it (@items) {
        next if seen_recently($it->[1]);
        spawn_worker($it->[1], $pane, $it->[0]);
    }
}

sub on_public {
    my ($server, $msg, $nick, $addr, $target) = @_;
    handle_text($msg, $target);
}

sub on_private {
    my ($server, $msg, $nick, $addr) = @_;
    handle_text($msg, $nick);
}

# /wezterm_img_test <url>  — inject an image or webpage URL as if received
sub cmd_test {
    my ($data, $server, $witem) = @_;
    $data =~ s/^\s+|\s+$//g;
    if ($data eq '') {
        Irssi::print('usage: /wezterm_img_test <image-or-webpage-url>');
        return;
    }
    # bypass dedupe + channel filter for manual testing
    delete $SEEN_SET{$data};
    my $mode = effective_mode();
    if ($mode eq 'off' || $mode eq 'inactive') {
        Irssi::print("wezterm_img: mode is '$mode' — nothing to do (see /set wezterm_img_mode)");
        return;
    }
    handle_text($data, undef);
    my $where = $mode eq 'remote' ? 'queued to ' . queue_file() : 'rendering locally';
    Irssi::print("wezterm_img: $data ($where)");
}

# /wezterm_img_close — dismiss the side pane.
sub cmd_close {
    my $mode = effective_mode();
    if ($mode eq 'remote') {
        enqueue_item('close', '-');
        Irssi::print('wezterm_img: close requested (remote watcher will dismiss the pane)');
        return;
    }
    if (defined $VIEWER_PANE) {
        system("wezterm cli kill-pane --pane-id $VIEWER_PANE >/dev/null 2>&1");
    }
    $VIEWER_PANE = undef;
    unlink(state_dir() . '/pane');
    Irssi::print('wezterm_img: preview pane closed');
}

# make sure the state dir exists at load time
mkdir(state_dir()) unless -d state_dir();

Irssi::signal_add('message public',  \&on_public);
Irssi::signal_add('message private', \&on_private);
Irssi::command_bind('wezterm_img_test',  \&cmd_test);
Irssi::command_bind('wezterm_img_close', \&cmd_close);

{
    my $mode = effective_mode();
    my %msg = (
        local    => '%Gmode=local%n — rendering previews in a WezTerm side pane.',
        remote   => '%Gmode=remote%n — queueing previews to ' . queue_file()
                    . ' for a local watcher.',
        inactive => '%Ymode=auto%n — not inside WezTerm. If irssi is remote (ssh/mosh), '
                    . 'use %_/set wezterm_img_mode remote%_ and run watch_remote.sh locally.',
        off      => '%Kmode=off%n — disabled.',
    );
    my $sites = Irssi::settings_get_bool('wezterm_img_sites') ? 'on' : 'off';
    Irssi::print("%G>>%n wezterm_img $VERSION loaded. " . ($msg{$mode} || ''));
    Irssi::print("%G>>%n webpage previews %_$sites%_ (/set wezterm_img_sites); "
               . '/wezterm_img_close dismisses the pane.');
}
