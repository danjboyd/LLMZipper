#!/usr/bin/env perl
use strict;
use warnings;
use v5.16;
use utf8;

use Gtk3 -init;
use Glib qw/TRUE FALSE/;
use File::Basename qw/basename dirname/;
use File::Spec;
use Cwd qw/abs_path/;
use Path::Tiny;
use Archive::Zip qw/:ERROR_CODES :CONSTANTS/;
use POSIX qw/strftime/;
use JSON::PP;
use Encode qw(decode_utf8);
use URI::Escape qw(uri_escape);
use File::Copy qw(copy);
use Fcntl qw(:mode);
use threads;
use threads::shared;
use Thread::Queue;

# Make a filesystem-friendly slug from the active profile
sub _profile_slug {
  my ($name) = @_;
  $name //= '';
  $name =~ s/^\s+|\s+$//g;           # trim
  $name = length($name) ? $name : 'Default';
  # Replace non filename-friendly chars with underscores
  $name =~ s{[^\w\.\-]+}{_}g;        # keep [A-Za-z0-9_] and dot/dash
  # Avoid starting with a dot (hidden)
  $name =~ s/^\./_/;
  return $name;
}

# ------------------------------------------------------------
# Config paths
# ------------------------------------------------------------
sub _xdg_config_dir {
  my $home = $ENV{XDG_CONFIG_HOME} // File::Spec->catdir($ENV{HOME} // '', '.config');
  return File::Spec->catdir($home, 'llmzip');
}
my $CONFIG_DIR  = _xdg_config_dir();
my $STATE_FILE  = File::Spec->catfile($CONFIG_DIR, 'state.json');
my $FILTER_FUNC_SET   = 0;   # have we set the filter's visible_func?
my $COL_FUNCS_SET     = 0;   # have we set the col_name cell-data funcs?
my @SIGNAL_IDS;              # [[$obj,$id], ...] to disconnect on shutdown

# Public export dir helpers
sub _xdg_download_dir {
  my $home = $ENV{HOME} // '';
  my $dl   = File::Spec->catdir($home, 'Downloads');

  my $xdg_cfg_root = $ENV{XDG_CONFIG_HOME} // File::Spec->catdir($home, '.config');
  my $xdg_file     = File::Spec->catfile($xdg_cfg_root, 'user-dirs.dirs');
  if (-f $xdg_file) {
    if (open my $fh, '<', $xdg_file) {
      while (<$fh>) {
        if (/^XDG_DOWNLOAD_DIR="?([^"]+)"?/) {
          my $p = $1;
          $p =~ s/^\$HOME/$home/;
          $p =~ s/^"|"$//g;
          $dl = $p if $p;
          last;
        }
      }
      close $fh;
    }
  }
  return $dl;
}

sub _public_export_dir {
  my $root = _xdg_download_dir();
  return File::Spec->catdir($root, 'LLMZips');
}

sub _file_uri {
  my ($path) = @_;
  my $abs = abs_path($path) // $path;
  my $uri = 'file://' . $abs;
  # Escape only characters unsafe in a URI path segment; keep slashes
  $uri =~ s{([^A-Za-z0-9\-\._~/])}{uri_escape($1)}ge;
  return $uri;
}

# ------------------------------------------------------------
# UI
# ------------------------------------------------------------
my $builder = Gtk3::Builder->new;
$builder->add_from_file(path( dirname( __FILE__ ), 'llmzip.ui' ) );
my $win = $builder->get_object('main_window');

$win->signal_connect(delete_event => sub {
  save_state();
  _shutdown_background_tasks();  # stop workers, remove sources, etc.
  return FALSE;                  # allow destroy to proceed
});

$win->signal_connect(destroy => sub {
  Gtk3->main_quit;               # do NOT call shutdown here again
});

$SIG{INT}  = sub { _shutdown_background_tasks(); Gtk3->main_quit; };
$SIG{TERM} = sub { _shutdown_background_tasks(); Gtk3->main_quit; };

# Widgets
my (
  $add_root_button,$remove_root_button,
  $roots_combo,$show_hidden_check,$tree_search_entry,$project_treeview,$refresh_button,$zip_now_button,
  $preview_treeview,$preview_summary_label,$status_last_scan_label,$status_last_zip_label,$status_profile_label,
  $copy_clipboard_button,$copy_path_button,
  $profiles_combo,$profile_new_button,$profile_rename_button,$profile_delete_button
) = map { $builder->get_object($_) } qw(
  add_root_button remove_root_button
  roots_combo show_hidden_check tree_search_entry project_treeview refresh_button zip_now_button
  preview_treeview preview_summary_label status_last_scan_label status_last_zip_label status_profile_label
  copy_clipboard_button copy_path_button
  profiles_combo profile_new_button profile_rename_button profile_delete_button
);

my $search_spinner = $builder->get_object('search_spinner');
my $renderer_toggle = $builder->get_object('renderer_toggle');
my $renderer_star = $builder->get_object('renderer_star');
my $renderer_text = $builder->get_object('renderer_text');
my $col_name = $builder->get_object('col_name');

# Yellow star via markup (no theme dependency)
$builder->get_object('col_name')->set_cell_data_func(
  $renderer_star,
  sub {
    my ($col,$cell,$model,$iter,$data) = @_;
    my ($fav) = $model->get($iter,7);

    if ($fav) {
      # Tweak the color to taste; these two look nice:
      # my $color = '#F6C343';  # warm gold
      my $color = '#FFC107';    # material-ish amber
      $cell->set(
        markup => qq{<span foreground="$color">★</span>},  # Unicode star
        xalign => 0.0,
      );
    } else {
      $cell->set(markup => '');  # no star
    }
  }, undef
);

# Bold favorites (markup)
$builder->get_object('col_name')->set_cell_data_func(
  $renderer_text,
  sub {
    my ($col,$cell,$model,$iter,$data) = @_;
    my ($name,$fav) = $model->get($iter,1,7);
    my $safe = $name // '';
    $safe =~ s/&/&amp;/g; $safe =~ s/</&lt;/g; $safe =~ s/>/&gt;/g;
    my $markup = $fav ? "<b>$safe</b>" : $safe;
    $cell->set(markup => $markup);
  }, undef
);
$COL_FUNCS_SET = 1;

# ------------------------------------------------------------
# Model columns (TreeStore)
# 0 included(bool) | 1 name | 2 icon_name | 3 fullpath | 4 is_dir(bool)
# 5 inconsistent(bool) | 6 root_alias
# ------------------------------------------------------------
my $tree_store = Gtk3::TreeStore->new(
  'Glib::Boolean','Glib::String','Glib::String',
  'Glib::String','Glib::Boolean','Glib::Boolean','Glib::String','Glib::Boolean'
);

# Wrap in a filter so we can live-filter by name
my $filter_model = Gtk3::TreeModelFilter->new($tree_store, undef);
$filter_model->set_visible_func(\&filter_visible, undef);
$FILTER_FUNC_SET = 1;
$project_treeview->set_model($filter_model);

my $hid;

$hid = $renderer_toggle->signal_connect(toggled => \&on_toggle_include);
push @SIGNAL_IDS, [$renderer_toggle, $hid];

# Preview model: [included,bool, root, rel, size, mtime, reason, abs(hidden)]
my $preview_store = Gtk3::ListStore->new(
  'Glib::Boolean','Glib::String','Glib::String',
  'Glib::String','Glib::String','Glib::String','Glib::String'
);
$preview_treeview->set_model($preview_store);


# ------------------------------------------------------------
# State (Profiles + per-profile data)
# ------------------------------------------------------------
my $CURRENT_PROFILE = 'Default';
my %STATE = (
  last_profile => $CURRENT_PROFILE,
  profiles     => {
    $CURRENT_PROFILE => {
      roots=>[], selected_files=>[], expanded_dirs=>[],
      favorites=>[], preview_excluded=>[],
    },
  },
);

# Working copies bound to current profile
my @ROOTS;                         # [{alias, path}...]
my %SELECTED_FILES;                # abs_path => 1
my %EXPANDED_DIRS;                 # abs_dir_path => 1
my $LAST_ZIP_PATH;                 # absolute path to most recent ZIP
my %FAVORITES;  # abs_path => 1
my %PREVIEW_EXCLUDED;   # abs_path => 1 when temporarily excluded in Preview
# ---------- Content search (threaded) ----------
my %CONTENT_HITS;                 # abs_path => 1 when contents match
my $CONTENT_NEEDLE = '';          # current needle (lowercased)

# Queues + workers
my $work_q    = Thread::Queue->new;     # jobs: { gen, path } or { cmd=>'quit' }
my $result_q  = Thread::Queue->new;     # results: [ gen, abs_path ]
my @workers;                             # threads

# Generation token for cancellation
my $ACTIVE_GEN :shared = 0;              # bump on every new search
my $RESULT_IDLE_ID;                      # Glib::Idle id for draining result_q
my $SEARCH_TIMER_ID;                     # debounce timer id

# Tuning
my $NUM_WORKERS      = 4;                # tweak for your box
my $MAX_SCAN_BYTES   = 2 * 1024 * 1024;  # cap read per file
my %EXPANDED_DIRS_BEFORE_SEARCH;   # abs_dir_path => 1 (snapshot before search starts)

# Spinner / work tracking
my $ENQUEUED_GEN     :shared = 0;  # generation for which outstanding count applies
my $JOBS_OUTSTANDING :shared = 0;  # number of queued files not yet processed
my $SHUTTING_DOWN = 0;        # we’re in teardown; don’t schedule/refilter
my @REFILTER_IDLE_IDS;        # one-shot idle IDs from refilter_preserving_expansion()
my %REFILTER_IDLE_ACTIVE;  # id => 1 while pending; removed when it fires or we cancel
my $SEARCH_ACTIVE :shared = 0;

sub _profile { $STATE{profiles}{$CURRENT_PROFILE} }

# ------------------------------------------------------------
# Persistence
# ------------------------------------------------------------
sub load_state {
  if (-f $STATE_FILE) {
    my $json = Path::Tiny->new($STATE_FILE)->slurp_raw;
    my $data = eval { decode_json($json) } || {};
    %STATE = (
      last_profile => ($data->{last_profile} // 'Default'),
      profiles     => ($data->{profiles}     // {}),
    );
  }

  # Ensure current profile exists
  $CURRENT_PROFILE = $STATE{last_profile} || 'Default';
  # default profile scaffold
  $STATE{profiles}{$CURRENT_PROFILE} //= {
    roots=>[], selected_files=>[], expanded_dirs=>[], favorites=>[],
    preview_excluded=>[],  # NEW
  };



  # Bind to working vars
  my $p = _profile();
  @ROOTS          = @{ $p->{roots} // [] };
  %SELECTED_FILES = map { $_ => 1 } @{ $p->{selected_files} // [] };
  %EXPANDED_DIRS  = map { $_ => 1 } @{ $p->{expanded_dirs}  // [] };
  # bind working vars
  %FAVORITES = map { $_ => 1 } @{ $p->{favorites} // [] };
  %PREVIEW_EXCLUDED = map { $_ => 1 } @{ $p->{preview_excluded} // [] };  # NEW

}

sub save_state {
  cache_selected_files();
  cache_expanded_rows();

  # Write back working vars into current profile
  my $p = _profile();
  $p->{roots}          = [ @ROOTS ];
  $p->{selected_files} = [ sort keys %SELECTED_FILES ];
  $p->{expanded_dirs}  = [ sort keys %EXPANDED_DIRS  ];
  $p->{favorites} = [ sort keys %FAVORITES ];
  $p->{preview_excluded}= [ sort keys %PREVIEW_EXCLUDED ];   # <-- ADD THIS


  $STATE{last_profile} = $CURRENT_PROFILE;

  Path::Tiny->new($CONFIG_DIR)->mkpath;
  Path::Tiny->new($STATE_FILE)->spew_raw(encode_json(\%STATE));
}

# ------------------------------------------------------------
# Background thread workers
# ------------------------------------------------------------
sub _start_content_workers {
  return if @workers;
  for (1..$NUM_WORKERS) {
    push @workers, threads->create(sub {
      while (1) {
        my $job = $work_q->dequeue;                   # blocking
        if (ref($job) eq 'HASH' && ($job->{cmd}//'') eq 'quit') {
          threads->exit();                            # hard exit this worker
        }

        my ($gen,$path) = @$job{qw/gen path/};

        # Double-check generation *before* and *after* the scan
        my $is_current = ($gen == $ACTIVE_GEN);

        if ($is_current &&
            _file_contains_needle_threadsafe($path, $CONTENT_NEEDLE, $MAX_SCAN_BYTES)) {
          # Guard again at enqueue time to avoid racing with a new gen
          if ($gen == $ACTIVE_GEN) {
            $result_q->enqueue([$gen,$path]);
          }
        }

        # Mark one job done for the generation we counted
        if (defined $gen && $gen == $ENQUEUED_GEN) {
          lock($JOBS_OUTSTANDING);
          $JOBS_OUTSTANDING-- if $JOBS_OUTSTANDING > 0;
        }
      }
    });
  }
}

sub _stop_content_workers {
  return unless @workers;
  # signal quits
  $work_q->enqueue({ cmd => 'quit' }) for 1..@workers;
  $_->join for splice @workers;
}

sub _shutdown_background_tasks {
  return if $SHUTTING_DOWN;
  $SHUTTING_DOWN = 1;

  # 1) Disconnect risky signal handlers first
  eval {
    for my $pair (@SIGNAL_IDS) {
      my ($obj,$id) = @$pair;
      next unless $obj && $id;
      $obj->signal_handler_disconnect($id);
    }
    @SIGNAL_IDS = ();
    1;
  };

  # 2) Unset cell-data funcs exactly once (so GTK won't call our closures in dispose)
  eval {
    if ($COL_FUNCS_SET) {
      my $col_name = $builder->get_object('col_name');
      if ($col_name && $renderer_star) { $col_name->set_cell_data_func($renderer_star, undef, undef) }
      if ($col_name && $renderer_text) { $col_name->set_cell_data_func($renderer_text, undef, undef) }
      $COL_FUNCS_SET = 0;
      # Optional: physically remove the column to avoid any last lookups
      $project_treeview->remove_column($col_name) if $project_treeview && $col_name;
    }
    1;
  };

  # 3) Detach models so views won't poke them further
  eval {
    $project_treeview->set_model(undef) if $project_treeview;
    $preview_treeview->set_model(undef) if $preview_treeview;
    1;
  };
  { lock($SEARCH_ACTIVE); $SEARCH_ACTIVE = 0; }
  _update_search_spinner();  # guarded by $SHUTTING_DOWN returns fast, but fine

}


sub _file_contains_needle_threadsafe {
  my ($abs, $needle, $limit) = @_;
  return 0 if $needle eq '' || !-r $abs || !-f $abs;

  open my $fh, '<:raw', $abs or return 0;
  my $buf = '';
  my $to  = $limit // $MAX_SCAN_BYTES;
  my $chunk = 8192;

  while ($to > 0) {
    my $read = read($fh, my $tmp, $to > $chunk ? $chunk : $to) or last;
    $buf .= $tmp;
    $to  -= $read;
    return 0 if index($tmp, "\x00") >= 0;  # treat as binary; skip
  }
  close $fh;

  my $text = eval { decode_utf8($buf, 1) };
  $text = $buf unless defined $text;       # fall back raw
  return index(lc($text), $needle) >= 0 ? 1 : 0;
}

sub _kickoff_threaded_content_search {
  return if $SHUTTING_DOWN;
  my $raw = $tree_search_entry->get_text // '';
  my $needle = lc $raw;

  # Take/restore expansion baseline across the whole search lifecycle
  if ($CONTENT_NEEDLE eq '' && $needle ne '') {
    # starting a new search: remember current expansion
    cache_expanded_rows();
    %EXPANDED_DIRS_BEFORE_SEARCH = %EXPANDED_DIRS;
  } elsif ($CONTENT_NEEDLE ne '' && $needle eq '') {
    # search cleared: restore the pre-search expansion snapshot
    %EXPANDED_DIRS = %EXPANDED_DIRS_BEFORE_SEARCH;
  }

  # Fast path: if needle unchanged, just refilter names
  if ($needle eq $CONTENT_NEEDLE) {
    refilter_preserving_expansion() if defined &refilter_preserving_expansion;
    _update_search_spinner();
    return;
  }

  # Cancel previous: bump generation + clear state
  {
    lock($ACTIVE_GEN);
    $ACTIVE_GEN++;                     # workers will ignore prior gen
  }
  {
    lock($ENQUEUED_GEN);     $ENQUEUED_GEN = $ACTIVE_GEN;
    lock($JOBS_OUTSTANDING); $JOBS_OUTSTANDING = 0;
  }
  {
    lock($SEARCH_ACTIVE); $SEARCH_ACTIVE = 1;
  }
  _update_search_spinner();    # show & animate immediately

  $CONTENT_NEEDLE = $needle;
  %CONTENT_HITS   = ();

  # Clear any pending results from prior gen
  while ($result_q->dequeue_nb) { }    # drain

  # If needle empty, show name-only filter
  if ($CONTENT_NEEDLE eq '') {
    refilter_preserving_expansion();
    return;
  }

  # Build a fresh job list for all files in all roots (respect Show hidden)
  my $hide_hidden = !$show_hidden_check->get_active;
  for my $r (@ROOTS) {
    my $root = abs_path($r->{path}) // next;
    _enqueue_dir_jobs($root, $hide_hidden);
  }

  # Ensure a result-drain idle is running
  $RESULT_IDLE_ID //= Glib::Idle->add(\&_drain_content_results);

  # Immediate refilter so filename hits show; content hits will stream in
  refilter_preserving_expansion() if defined &refilter_preserving_expansion; # your helper
  _update_search_spinner();
}

sub _enqueue_dir_jobs {
  my ($dir, $hide_hidden) = @_;
  opendir(my $dh, $dir) or return;
  while (defined(my $e = readdir($dh))) {
    next if $e eq '.' || $e eq '..';
    next if $hide_hidden && $e =~ /^\./;
    my $p = File::Spec->catfile($dir,$e);
    if (-d $p) {
      _enqueue_dir_jobs($p, $hide_hidden);
    } elsif (-f _) {
      my $abs = abs_path($p) // $p;
      $work_q->enqueue({ gen => $ACTIVE_GEN, path => $abs });
      { lock($JOBS_OUTSTANDING); $JOBS_OUTSTANDING++; }
    }
  }
  closedir $dh;
}

sub _drain_content_results {
  return FALSE if $SHUTTING_DOWN || !Gtk3::main_level(); # main loop gone; stop
  my $changed = 0;
  while (my $r = $result_q->dequeue_nb) {
    my ($gen,$abs) = @$r;
    next if $gen != $ACTIVE_GEN;
    next if $CONTENT_HITS{$abs};
    $CONTENT_HITS{$abs} = 1;
    $changed = 1;
  }
  refilter_preserving_expansion() if $changed;

  _update_search_spinner();  # <-- add this
  # after _update_search_spinner();
  if ($JOBS_OUTSTANDING <= 0 && !$result_q->pending) {
    lock($SEARCH_ACTIVE); $SEARCH_ACTIVE = 0;
    _update_search_spinner();   # hides it
  }

  if ($CONTENT_NEEDLE ne '' || $result_q->pending) {
    return TRUE;
  } else {
    $RESULT_IDLE_ID = undef;
    return FALSE;
  }
}


# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

sub _update_search_spinner {
  return if $SHUTTING_DOWN;

  my $active;
  {
    # primary: explicit flag
    $active = $SEARCH_ACTIVE;
    # fallback: tolerate race where flag isn't set yet but jobs are enqueued
    $active ||= ($CONTENT_NEEDLE ne '' && ($JOBS_OUTSTANDING > 0 || $result_q->pending));
  }

  if ($active) {
    $search_spinner->show;
    $search_spinner->start;
  } else {
    $search_spinner->stop;
    $search_spinner->hide;
  }
}

sub refilter_preserving_expansion {
  return if $SHUTTING_DOWN;
  cache_expanded_rows();
  $filter_model->refilter;

  my $id; $id = Glib::Idle->add(sub {
    delete $REFILTER_IDLE_ACTIVE{$id};      # mark done first
    return FALSE if $SHUTTING_DOWN || !Gtk3::main_level();
    restore_expanded_rows();
    return FALSE;
  });
  $REFILTER_IDLE_ACTIVE{$id} = 1;
}

sub unique_alias {
  my ($base) = @_;
  my $alias = $base;
  my %used = map { $_->{alias} => 1 } @ROOTS;
  my $i = 2;
  while ($used{$alias}) { $alias = $base . '_' . $i++; }
  return $alias;
}

sub refresh_roots_combo {
  $roots_combo->remove_all;
  $roots_combo->append_text($_->{alias}) for @ROOTS;
  $roots_combo->set_active(0) if @ROOTS;
}

sub is_favorite {
  my ($abs) = @_;
  return $abs && $FAVORITES{$abs};
}

sub add_tree_row {
  my ($parent,$label,$icon,$full,$is_dir,$alias,$checked) = @_;
  my $it = $tree_store->append($parent);
  $tree_store->set($it,
    0 => $checked?TRUE:FALSE,
    1 => $label,
    2 => ($icon // ''),
    3 => $full,
    4 => $is_dir?TRUE:FALSE,
    5 => FALSE,
    6 => $alias,
    7 => is_favorite($full) ? TRUE : FALSE,  # NEW
  );
  return $it;
}

sub _sorted_children {
  my ($dir,$hide_hidden) = @_;
  opendir(my $dh,$dir) or return ();
  my @all = grep {
    $_ ne '.' && $_ ne '..' && !($hide_hidden && /^\./)
  } readdir($dh);
  closedir $dh;

  my @fav; my @rest;
  for my $e (@all) {
    my $abs = abs_path(File::Spec->catfile($dir,$e));
    (is_favorite($abs) ? push @fav,$e : push @rest,$e);
  }
  return ( (sort { lc($a) cmp lc($b) } @fav),
           (sort { lc($a) cmp lc($b) } @rest) );
}


sub _walk_dir {
  my ($path,$parent_iter,$hide_hidden,$alias) = @_;
  my $is_dir = -d $path;
  my $name = (File::Spec->splitpath($path))[2];
  my $abs = abs_path($path);
  my $checked = (!$is_dir && $abs && $SELECTED_FILES{$abs}) ? 1 : 0;
  my $iter = add_tree_row($parent_iter, $name, ($is_dir?'folder-symbolic':'text-x-generic-symbolic'),
                          ($abs // $path), $is_dir, $alias, $checked);
  if ($is_dir) {
    opendir(my $dh,$path) or return;
    for my $c (_sorted_children( $path, $hide_hidden) ) {
      next if $c eq '.' || $c eq '..';
      next if $hide_hidden && $c =~ /^\./;
      _walk_dir(File::Spec->catfile($path,$c), $iter, $hide_hidden, $alias);
    }
    closedir $dh;
  }
}

sub rebuild_tree_from_roots {
  $tree_store->clear;
  my $hide_hidden = !$show_hidden_check->get_active;

  for my $r (@ROOTS) {
    my $root_path = abs_path($r->{path}) // next;
    my $root_iter = add_tree_row(undef, $r->{alias}, 'folder-symbolic', $root_path, 1, $r->{alias}, 0);
    opendir(my $dh,$root_path) or next;
    for my $e (_sorted_children( $root_path, $hide_hidden)) {
      next if $e eq '.' || $e eq '..';
      next if $hide_hidden && $e =~ /^\./;
      _walk_dir(File::Spec->catfile($root_path,$e), $root_iter, $hide_hidden, $r->{alias});
    }
    closedir $dh;
  }

  restore_expanded_rows();  # converts cached abs paths into paths in filter model
  _recompute_all_tristate();
  refilter_preserving_expansion();
}

# ---------------- filter (live) -----------------
sub filter_visible {
  return TRUE if $SHUTTING_DOWN;            # <-- add this line
  my ($model,$iter,$data) = @_;
  my $needle = lc($tree_search_entry->get_text // '');
  return TRUE if $needle eq '';

  my ($name,$full,$is_dir) = $model->get($iter,1,3,4);
  my $name_hit = (index(lc($name // ''), $needle) >= 0);

  if (!$is_dir) {
    my $content_hit = $CONTENT_HITS{$full} ? 1 : 0;
    return ($name_hit || $content_hit) ? TRUE : FALSE;
  }

  # Directory: show if name matches or any descendant matches
  return TRUE if $name_hit;
  return _descendant_matches($model, $iter, $needle) ? TRUE : FALSE;
}

sub _descendant_matches {
  my ($model,$iter,$needle) = @_;
  my $n = $model->iter_n_children($iter);
  for (my $i=0;$i<$n;$i++) {
    my $child = $model->iter_nth_child($iter,$i);
    my ($name,$full,$is_dir) = $model->get($child,1,3,4);
    return 1 if index(lc($name // ''), $needle) >= 0;
    return 1 if !$is_dir && $CONTENT_HITS{$full};
    return 1 if  $is_dir && _descendant_matches($model,$child,$needle);
  }
  return 0;
}

$hid = $tree_search_entry->signal_connect(changed => sub {
  if (defined $SEARCH_TIMER_ID) { Glib::Source->remove($SEARCH_TIMER_ID) }
  $SEARCH_TIMER_ID = Glib::Timeout->add(250, sub {
    $SEARCH_TIMER_ID = undef;
    _kickoff_threaded_content_search();
    return FALSE;
  });
});
push @SIGNAL_IDS, [$tree_search_entry, $hid];


my $popup_menu = Gtk3::Menu->new;
my $mi_toggle = Gtk3::MenuItem->new('Toggle Favorite');
$popup_menu->append($mi_toggle);
$popup_menu->show_all;

my $last_path_for_popup;
$hid = $project_treeview->signal_connect(button_press_event => sub {
  my ($view,$event) = @_;
  if ($event->button == 3) { # right-click
    my ($x,$y) = ($event->x,$event->y);
    my ($path,$col,$cellx,$celly) = $view->get_path_at_pos($x,$y);
    return FALSE unless $path;
    $last_path_for_popup = $path;
    $popup_menu->popup_at_pointer($event);
    return TRUE;
  }
  return FALSE;
});
push @SIGNAL_IDS, [$project_treeview, $hid];

$hid = $mi_toggle->signal_connect(activate => sub {
  return unless $last_path_for_popup;
  my $fit = $filter_model->get_iter($last_path_for_popup) or return;
  my $cit = $filter_model->convert_iter_to_child_iter($fit);
  my ($full,$fav,$is_dir) = $tree_store->get($cit,3,7,4);
  if ($full) {
    if ($fav) { delete $FAVORITES{$full} } else { $FAVORITES{$full} = 1 }
    $tree_store->set($cit, 7 => $FAVORITES{$full} ? TRUE : FALSE);

    # Re-sort the visible container
    cache_selected_files(); cache_expanded_rows();
    rebuild_tree_from_roots();
    refresh_preview_from_selection();
    save_state();
  }
});
push @SIGNAL_IDS, [$mi_toggle, $hid];

# ------------- expansion/selection cache (convert between filter/child) ------
sub cache_expanded_rows {
  return if $SHUTTING_DOWN;
  %EXPANDED_DIRS = ();
  $project_treeview->map_expanded_rows(sub {
    my ($view,$fpath) = @_;
    my $fit = $filter_model->get_iter($fpath) or return;
    my $cit = $filter_model->convert_iter_to_child_iter($fit);
    my ($full,$is_dir) = $tree_store->get($cit,3,4);
    $EXPANDED_DIRS{$full} = 1 if $is_dir;
  });
}

sub restore_expanded_rows {
  return if $SHUTTING_DOWN || !Gtk3::main_level();
  my $cit = $tree_store->get_iter_first or return;
  _maybe_expand_child_iter($cit);
  while ($tree_store->iter_next($cit)) { _maybe_expand_child_iter($cit); }
}

sub _maybe_expand_child_iter {
  return if $SHUTTING_DOWN;
  my ($cit) = @_;
  my ($full,$is_dir) = $tree_store->get($cit,3,4);
  if ($is_dir && $EXPANDED_DIRS{$full}) {
    my $cpath = $tree_store->get_path($cit);
    my $fpath = $filter_model->convert_child_path_to_path($cpath);
    return unless defined $fpath && Gtk3::main_level();
    $project_treeview->expand_row($fpath, FALSE);
  }
  my $n = $tree_store->iter_n_children($cit);
  for (my $i=0;$i<$n;$i++) { _maybe_expand_child_iter($tree_store->iter_nth_child($cit,$i)); }
}

sub cache_selected_files {
  %SELECTED_FILES = ();
  my $cit = $tree_store->get_iter_first or return;
  _collect_checked_child($cit);
  while ($tree_store->iter_next($cit)) { _collect_checked_child($cit); }
}
sub _collect_checked_child {
  my ($cit) = @_;
  my ($on,$full,$is_dir) = $tree_store->get($cit,0,3,4);
  if ($on && !$is_dir) { $SELECTED_FILES{$full} = 1; }
  my $n = $tree_store->iter_n_children($cit);
  for (my $i=0;$i<$n;$i++) { _collect_checked_child($tree_store->iter_nth_child($cit,$i)); }
}

# ------------- tri-state logic on child model ----------------
sub on_toggle_include {
  return if $SHUTTING_DOWN;
  my ($cell,$fpath_str) = @_;
  my $fpath = Gtk3::TreePath->new_from_string($fpath_str);
  my $fit = $filter_model->get_iter($fpath);
  my $cit = $filter_model->convert_iter_to_child_iter($fit);
  my ($active) = $tree_store->get($cit,0);
  my $new = $active ? FALSE : TRUE;

  _set_subtree($cit,$new);
  _update_ancestors($cit);

  # NEW: live-update preview + persist selection immediately
  refresh_preview_from_selection();
  save_state();
}

sub _set_subtree {
  my ($cit,$state) = @_;
  $tree_store->set($cit, 0=>$state, 5=>FALSE);
  my $n = $tree_store->iter_n_children($cit);
  for (my $i=0;$i<$n;$i++) {
    _set_subtree($tree_store->iter_nth_child($cit,$i), $state);
  }
}
sub _update_ancestors {
  my ($cit) = @_;
  while (1) {
    my $parent = $tree_store->iter_parent($cit) or last;
    my $n = $tree_store->iter_n_children($parent);
    my ($all_on,$all_off) = (1,1);
    for (my $i=0;$i<$n;$i++) {
      my $child = $tree_store->iter_nth_child($parent,$i);
      my ($on) = $tree_store->get($child,0);
      $all_on  &&= $on;
      $all_off &&= !$on;
    }
    if    ($all_on)  { $tree_store->set($parent, 0=>TRUE,  5=>FALSE); }
    elsif ($all_off) { $tree_store->set($parent, 0=>FALSE, 5=>FALSE); }
    else             { $tree_store->set($parent, 0=>TRUE,  5=>TRUE ); }
    $cit = $parent;
  }
}
sub _recompute_all_tristate {
  my $cit = $tree_store->get_iter_first or return;
  _recompute_from_child($cit);
  while ($tree_store->iter_next($cit)) { _recompute_from_child($cit); }
}
sub _recompute_from_child {
  my ($cit) = @_;
  my $n = $tree_store->iter_n_children($cit);
  for (my $i=0;$i<$n;$i++) { _recompute_from_child($tree_store->iter_nth_child($cit,$i)); }
  _update_ancestors($cit);
}

# Collect selection into array of [alias, abs, rel]
sub collect_selected_files {
  my @result;
  my $cit = $tree_store->get_iter_first or return \@result;
  _collect_under_child($cit,\@result);
  while ($tree_store->iter_next($cit)) { _collect_under_child($cit,\@result); }
  return \@result;
}
sub _collect_under_child {
  my ($cit,$out) = @_;
  my ($on,$full,$is_dir,$alias) = $tree_store->get($cit,0,3,4,6);
  if ($on && !$is_dir) {
    my ($root) = grep { index($full, abs_path($_->{path}))==0 } @ROOTS;
    my $root_dir = $root ? abs_path($root->{path}) : '';
    my $rel = $root_dir ? File::Spec->abs2rel($full, $root_dir) : basename($full);
    push @$out, [$alias,$full,$rel];
  }
  my $n = $tree_store->iter_n_children($cit);
  for (my $i=0;$i<$n;$i++) { _collect_under_child($tree_store->iter_nth_child($cit,$i), $out); }
}

sub refresh_preview_from_selection {
  $preview_store->clear;
  my $items = collect_selected_files();
  my ($count,$bytes) = (0,0);

  for my $it (@$items) {
    my ($alias,$abs,$rel) = @$it;

    my $size = -s $abs; $bytes += ($size||0); $count++;
    my $mtime = (stat($abs))[9]||0; my $ts = scalar localtime($mtime);

    my $included = $PREVIEW_EXCLUDED{$abs} ? FALSE : TRUE;  # <-- NEW

    my $row = $preview_store->append;
    $preview_store->set($row,
      0=>$included, 1=>$alias, 2=>$rel,
      3=>sprintf('%.1f KB', ($size||0)/1024), 4=>$ts, 5=>'selected',
      6=>$abs  # hidden abs path
    );
  }

  $preview_summary_label->set_text(sprintf('%d files — %.1f MB', $count, $bytes/1024/1024));
  $status_last_scan_label->set_text('Last scan: '.scalar localtime);
}

sub write_zip_from_selection {
  my $items = collect_selected_files();
  return unless @$items;

  my $zip = Archive::Zip->new;
  for my $it (@$items) {
    my ($alias,$abs,$rel) = @$it;
    my $arc = File::Spec->catfile($alias,$rel); $arc =~ s#\\#/#g;
    $zip->addFile($abs,$arc);
  }

  my $base   = @ROOTS ? $ROOTS[0]{path} : '.';
  my $outdir = Path::Tiny->new($base)->child('.llmzip','exports'); $outdir->mkpath;
  my $slug   = _profile_slug($CURRENT_PROFILE);
  my $name   = $slug.'-'.strftime('%Y%m%d-%H%M', localtime).'.zip';
  my $out    = $outdir->child($name);

  my $ok = $zip->writeToFileNamed($out->stringify);
  if ($ok != AZ_OK) { warn "Zip write failed ($ok)\n"; return; }

  $LAST_ZIP_PATH = abs_path($out->stringify);
  $status_last_zip_label->set_text('Last zip: '.$LAST_ZIP_PATH);

  # 1) Add to GTK Recents (to appear under "Recent" in file pickers)
  eval {
    my $mgr = Gtk3::RecentManager::get_default();
    my $uri = _file_uri($LAST_ZIP_PATH);
    $mgr->add_item($uri);
    1;
  } or do {
    warn "Failed to add to recent files: $@";
  };

  # 2) Mirror into public Downloads/LLMZips
  my $pub_dir = Path::Tiny->new(_public_export_dir());
  $pub_dir->mkpath;

  my $pub_path = $pub_dir->child($name)->stringify;
  eval {
    copy($LAST_ZIP_PATH, $pub_path) or die "copy failed: $!";
    1;
  } or do {
    warn "Failed to copy ZIP to public folder: $@";
  };

  # Maintain latest.zip symlink
  eval {
    my $latest = $pub_dir->child('latest.zip')->stringify;
    unlink $latest if -l $latest || -e $latest;
    symlink(basename($pub_path), $latest) or warn "symlink failed: $!";
    1;
  };

  # 3) Open the public folder (easiest place to attach from)
  my $folder = $pub_dir->stringify;
  for my $cmd ( ['xdg-open',$folder], ['gio','open',$folder], ['gnome-open',$folder] ) {
    my $pid = fork();
    if (defined $pid && $pid == 0) { exec @$cmd; exit 0; }
    last if defined $pid;
  }
  return 1;
}

sub copy_selection_to_clipboard {
  my $items_all = collect_selected_files();
  return unless @$items_all;

  # Respect Preview inclusion (temporary)
  my @items = grep { my ($alias,$abs,$rel)=@$_; !$PREVIEW_EXCLUDED{$abs} } @$items_all;
  return unless @items;

  my $MAX_BYTES = 8 * 1024 * 1024; # 8 MB guardrail
  my $total_bytes = 0;

  my @chunks;
  for my $it (@items) {
    my ($alias,$abs,$rel) = @$it;

    my $raw;
    if (-f $abs) {
      eval {
        $raw = Path::Tiny->new($abs)->slurp_raw;
        1;
      } or do {
        push @chunks, "$rel\n[[error: could not read file]]\n", "--------\n";
        next;
      };

      my $is_binary = ($raw =~ /\x00/);
      my $text;

      if (!$is_binary) {
        $text = eval { decode_utf8($raw, 1) };
        $text = $raw unless defined $text; # fallback if uncertain
      } else {
        $text = "[[binary file skipped: ".(-s $abs // length($raw))." bytes]]";
      }

      push @chunks, $rel . "\n" . $text . "\n";
      $total_bytes += length($text);
      if ($total_bytes > $MAX_BYTES) {
        push @chunks, "\n[[truncated: exceeded ${MAX_BYTES}B limit]]\n";
        last;
      }
    } else {
      push @chunks, "$rel\n[[skipped: not a regular file]]\n";
    }

    push @chunks, "--------\n";
  }

  pop @chunks if @chunks && $chunks[-1] eq "--------\n";

  my $payload = join("", @chunks);

  my $clipboard = Gtk3::Clipboard::get_default($win->get_display);
  $clipboard->set_text($payload, -1);  # <-- FIX: avoid UTF-8 truncation
  $clipboard->store;

  $status_last_zip_label->set_text('Copied to clipboard at '.scalar localtime);
  return 1;
}

# ------------------------------------------------------------
# Profiles UI helpers
# ------------------------------------------------------------
sub refresh_profiles_combo {
  $profiles_combo->remove_all;
  my @names = sort keys %{ $STATE{profiles} };
  for my $name (@names) { $profiles_combo->append_text($name) }
  # set active to current
  my $idx = 0; my $i = 0;
  for my $name (@names) { $idx = $i if $name eq $CURRENT_PROFILE; $i++ }
  $profiles_combo->set_active($idx);
  $status_profile_label->set_text("Profile: $CURRENT_PROFILE");
}

sub switch_profile {
  my ($new) = @_;
  return if !defined $new || $new eq $CURRENT_PROFILE;
  save_state();
  $CURRENT_PROFILE = $new;

  # Ensure full scaffold for the target profile:
  $STATE{profiles}{$CURRENT_PROFILE} //= {
    roots=>[], selected_files=>[], expanded_dirs=>[],
    favorites=>[], preview_excluded=>[],                 # <-- ensure both present
  };

  my $p = _profile();
  @ROOTS            = @{ $p->{roots} // [] };
  %SELECTED_FILES   = map { $_ => 1 } @{ $p->{selected_files} // [] };
  %EXPANDED_DIRS    = map { $_ => 1 } @{ $p->{expanded_dirs}  // [] };
  %FAVORITES        = map { $_ => 1 } @{ $p->{favorites} // [] };          # <-- rebind
  %PREVIEW_EXCLUDED = map { $_ => 1 } @{ $p->{preview_excluded} // [] };   # <-- rebind

  refresh_roots_combo();
  rebuild_tree_from_roots();
  refresh_preview_from_selection();
  $status_profile_label->set_text("Profile: $CURRENT_PROFILE");
  save_state();
}


# ------------------------------------------------------------
# Signals
# ------------------------------------------------------------
$add_root_button->signal_connect(clicked => sub {
  my $dlg = Gtk3::FileChooserDialog->new('Select Root', $win, 'select-folder',
                                         'gtk-cancel' => 'cancel', 'gtk-open' => 'accept');
  my $resp = $dlg->run;
  my $folder = ($resp eq 'accept') ? $dlg->get_filename : undef;
  $dlg->destroy;
  return unless $folder;

  my $alias = unique_alias(basename($folder));
  push @ROOTS, { alias=>$alias, path=>$folder };

  refresh_roots_combo();
  rebuild_tree_from_roots();
  refresh_preview_from_selection();
  save_state();
});

$remove_root_button->signal_connect(clicked => sub {
  my $alias = $roots_combo->get_active_text // return;
  @ROOTS = grep { $_->{alias} ne $alias } @ROOTS;
  refresh_roots_combo();
  rebuild_tree_from_roots();
  refresh_preview_from_selection();
  save_state();
});
$refresh_button->signal_connect(clicked => sub {
  cache_selected_files();
  cache_expanded_rows();
  rebuild_tree_from_roots();
  refresh_preview_from_selection();
  save_state();
});
$zip_now_button->signal_connect(clicked => sub {
  refresh_preview_from_selection();
  write_zip_from_selection();
});
$copy_clipboard_button->signal_connect(clicked => sub {
  refresh_preview_from_selection();  # ensure state is current
  copy_selection_to_clipboard();
});
if ($copy_path_button) {
  $copy_path_button->signal_connect(clicked => sub {
    if ($LAST_ZIP_PATH && -f $LAST_ZIP_PATH) {
      my $cb = Gtk3::Clipboard::get_default($win->get_display);
      $cb->set_text($LAST_ZIP_PATH, -1);
      $cb->store;
      $status_last_zip_label->set_text('Path copied: '.$LAST_ZIP_PATH);
    } else {
      $status_last_zip_label->set_text('No recent ZIP to copy');
    }
  });
}

my $preview_toggle = $builder->get_object('preview_toggle');

$hid = $preview_toggle->signal_connect(toggled => sub {
  my ($cell, $path_str) = @_;
  my $path = Gtk3::TreePath->new_from_string($path_str);
  my $iter = $preview_store->get_iter($path) or return;

  my ($included, $abs) = $preview_store->get($iter, 0, 6);
  my $new = $included ? FALSE : TRUE;

  # Update row
  $preview_store->set($iter, 0 => $new);

  # Track overrides
  if ($new) { delete $PREVIEW_EXCLUDED{$abs} }
  else      { $PREVIEW_EXCLUDED{$abs} = 1 }
  save_state();
  refresh_preview_from_selection();
});
push @SIGNAL_IDS, [$preview_toggle, $hid];

# Profile controls
$profiles_combo->signal_connect(changed => sub {
  my $name = $profiles_combo->get_active_text // return;
  switch_profile($name);
});

$profile_new_button->signal_connect(clicked => sub {
  my $dlg = Gtk3::Dialog->new('New Profile', $win, ['modal']);
  my $entry = Gtk3::Entry->new; $entry->set_text('New Profile');
  $dlg->get_content_area->add($entry);
  $dlg->add_button('gtk-cancel' => 'cancel');
  $dlg->add_button('gtk-ok'     => 'accept');
  $dlg->show_all;
  my $resp = $dlg->run; my $name = $entry->get_text; $dlg->destroy;
  return unless $resp eq 'accept';
  $name =~ s/^\s+|\s+$//g; return unless length $name;
  return if exists $STATE{profiles}{$name};
  $STATE{profiles}{$name} = { roots=>[], selected_files=>[], expanded_dirs=>[] };
  $CURRENT_PROFILE = $name;
  refresh_profiles_combo();
  switch_profile($name);
});

$profile_rename_button->signal_connect(clicked => sub {
  my $old = $CURRENT_PROFILE // return;
  my $dlg = Gtk3::Dialog->new('Rename Profile', $win, ['modal']);
  my $entry = Gtk3::Entry->new; $entry->set_text($old);
  $dlg->get_content_area->add($entry);
  $dlg->add_button('gtk-cancel' => 'cancel');
  $dlg->add_button('gtk-ok'     => 'accept');
  $dlg->show_all;
  my $resp = $dlg->run; my $new = $entry->get_text; $dlg->destroy;
  return unless $resp eq 'accept';
  $new =~ s/^\s+|\s+$//g; return unless length $new;
  return if $new eq $old;
  return if exists $STATE{profiles}{$new};

  # move data
  $STATE{profiles}{$new} = delete $STATE{profiles}{$old};
  $CURRENT_PROFILE = $new;
  refresh_profiles_combo();
  switch_profile($new);
});

$profile_delete_button->signal_connect(clicked => sub {
  my $name = $CURRENT_PROFILE // return;
  my @names = sort keys %{ $STATE{profiles} };
  return if @names <= 1; # don't allow deleting the last profile

  my $dlg = Gtk3::MessageDialog->new($win,
    ['modal'], 'question', 'ok-cancel',
    "Delete profile '$name'? This cannot be undone.");
  my $resp = $dlg->run; $dlg->destroy;
  return unless $resp eq 'ok';

  delete $STATE{profiles}{$name};
  # switch to another existing profile
  ($CURRENT_PROFILE) = sort keys %{ $STATE{profiles} };
  refresh_profiles_combo();
  switch_profile($CURRENT_PROFILE);
});

# ------------------------------------------------------------
# Init
# ------------------------------------------------------------
load_state();
refresh_profiles_combo();
refresh_roots_combo();
rebuild_tree_from_roots();
refresh_preview_from_selection();

_start_content_workers();   # <-- start threads here (before mainloop)

$win->show_all;
Gtk3->main;

END {
  # If something bypassed our normal path, still stop/join workers
  if (@workers) {
    eval { _shutdown_background_tasks(); 1; };
  }
}

