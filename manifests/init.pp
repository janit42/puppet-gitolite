# This class is inherited by setup.pp and admin.pp
#
# It's intention is to have alle the config parameters.
#
# If you only use this class (and the setup), you can still do all admin work
# (manage users, permissions etc. throug the git repository 
# gitolite-admin.git.)
#
# Parameters:
# $reporoot:
#  path to the directory where you will store the repositories.
#  This does not have to be equal to the $users home directory.
#  defaults to $userhome
# $user:
#  the user to host the git repositories
#  this user needs a home directory to work with gitolite.
# $userhome:
#  the home directory of the user
# $user_ensure:
#  if true, $user will be created, if false, you have
#  to create the user with the homedirectory elsewhere.
#  defaults to true
# $umask:
#  see the rc file docs for how/why you might change this
#  defaults to '0077' which gives perms of '0700'
# $git_config_keys:
#  look for "git-config" in the documentation
#  default: '.*'
# $log_extra:
#  set to true for extra log details
#  default: false
# $log_dest:
#  array of log destinations.
#  available values are:
#    normal: normal gitolite logs
#    syslog: log to syslog
#    repo-log: log just the update records to
#              gl-log in the bare repo directory
#  defaults to ['normal']
# $roles:
#  Array of roles to add.
#  default: ['READERS', 'WRITERS']
# $site_info:
#  the 'info' command prints this as additional info
#  default to false
# $gitolite_hostname:
#  the hostname, to unset, set to false
#  defaults to $::hostname
# $local_code:
#  suggested locations for site-local gitolite code
#  defaults to '', no site-local code
# $additional_gitoliterc
#  hash of additional lines to add on gitolite.rc file
#  defaults to empty (beware of "' etc ...)
#  example:
#  { 'CACHE' => '"Redis"' }
# $commands:
#  Array of commands and features to enable
#  defaults to ['help', 'desc', 'info', 'perms' ]
# $admin_key_source      = false,
#  provide a admin key source (default to false)
# $admin_key             = false,
#  admin key (string) (default to false)
# $additional_gitoliterc_notrc
#  hash of additional lines to add on gitolite.rc file
#  after the rc vars
#  defaults to empty (beware of "' etc ...)
#  example:
#  { '$REF_OR_FILENAME_PATT' => 'qr(^[0-9a-zA-Z][-0-9a-zA-Z._\@/+ :%,]*$)' }
# $fetch_cron
#   if a cronjob should be established to fetch from remote repos
#   defaults to false

class gitolite (
  String  $user,
  String  $userhome,
  String  $reporoot                    = "${userhome}/repositories",
  Boolean $user_ensure                 = true,
  String  $umask                       = '0077',
  String  $git_config_keys             = '.*',
  Boolean $log_extra                   = false,
  Array   $log_dest                    = ['normal'],
  Array   $roles                       = ['READERS', 'WRITERS'],
  Boolean $site_info                   = false,
  String  $gitolite_hostname           = $::hostname,
  String  $local_code                  = '',
  Hash    $additional_gitoliterc       = {},
  Hash    $additional_gitoliterc_notrc = {},
  Array   $commands                    = [
    'help',
    'desc',
    'info',
    'perms',
    'writable',
    'ssh-authkeys',
    'git-config',
    'daemon',
    'gitweb',
  ],
  String  $package_ensure              = 'present',
  Array   $packages                    = [],
  Array   $additional_packages         = [],
  String  $admin_key_source            = '',
  String  $admin_key                   = '',
  Boolean $fetch_cron                  = false,
) {

  ensure_packages($::gitolite::additional_packages)

  package{ $packages :
    ensure => $::gitolite::package_ensure,
    tag    => 'gitolite',
  }

  #contain ::gitolite::setup
  if $user_ensure {
    user{$user:
      ensure     => present,
      comment    => 'gitolite user',
      home       => $userhome,
      managehome => true,
      system     => true,
      before     => Exec['gitolite_setup'],
    }
    # create an ssh key for gitolite user
    file { "${userhome}/.ssh":
      ensure  => directory,
      owner   => $user,
      group   => $user,
      mode    => '0700',
      require => User[$user],
    }

    class{'::gitolite::ssh_key':
      filename => "${userhome}/.ssh/id_ed25519",
      type     => 'ed25519',
      user     => $user,
      require  => File["${userhome}/.ssh"],
    }
  }

  Exec {
    path    => ['/usr/bin', '/usr/sbin', '/bin'],
  }

  exec{'gitolite_setup':
    command => "su ${gitolite::user} -c 'gitolite setup -a dummy; mkdir ~/.gitolite/keydir'",
    unless  => "test -d ~${user}/.gitolite",
    creates => "${userhome}/.gitolite",
    require => Package[$packages],
  }

  -> exec{'gitolite_compile':
    command     => "su ${gitolite::user} -c 'gitolite compile'",
    refreshonly => true,
  }

  -> exec{'gitolite_trigger_post_compile':
    command     => "su ${gitolite::user} -c 'gitolite trigger POST_COMPILE'",
    refreshonly => true,
  }

  if "${userhome}/repositories" != $reporoot {
    file{ $reporoot:
      ensure => directory,
      owner  => $user,
      mode   => '0700',
    }

    -> exec{'gitolite: move repositories':
      command => "mv ${userhome}/repositories/* ${reporoot}/; true",
      unless  => [
        "test -h ${userhome}/repositories",  # symplink ?
      ],
    }

    # if linkpath is not a sym
    -> exec{'gitolite: remove repositories directory':
      command => "rmdir ${userhome}/repositories;ln -sf ${reporoot} ${userhome}/repositories",
      unless  => [
        "test -h ${userhome}/repositories",                              # symlink ?
        "test \"`readlink ${userhome}/repositories`\" == '${reporoot}'", # symlink to target ?
      ],
    }
  }

  file{"${userhome}/.gitolite.rc":
    content => template('gitolite/gitolite.rc.erb'),
    mode    => '0700',
    owner   => $user,
    notify  => Exec['gitolite_compile', 'gitolite_trigger_post_compile'],
  }

  $conffile = "${gitolite::userhome}/.gitolite/conf/gitolite.conf"
  $keydir   = "${gitolite::userhome}/.gitolite/keydir"
  $exec_update = Exec['gitolite_compile', 'gitolite_trigger_post_compile']

  # manage initial key, if provided
  if $admin_key_source != '' {
    file { "${keydir}/admin@init0.pub":
      source => $admin_key_source,
      notify => $exec_update,
    }
  }

  if $admin_key != '' {
    file { "${keydir}/admin@init1.pub":
      content => $admin_key,
      notify  => $exec_update,
    }
  }

  file{"${userhome}/scripts":
    ensure => directory,
    mode   => '0755',
    owner  => $user,
  }

  concat{ "${userhome}/upgrade-repos.sh":
    owner => 'root',
    group => 'root',
    mode  => '0700',
  }

  concat::fragment{ "${userhome}/upgrade-repos.sh header":
    target  => "${userhome}/upgrade-repos.sh",
    content => "#!/bin/sh\n#managed with puppet (module gitolite)\n\n",
    order   => '00',
  }

  if $fetch_cron {
    cron{'fetch gitolite repos upstream':
      command => "${userhome}/upgrade-repos.sh",
      user    => 'root',
      hour    => fqdn_rand(4, 'gitolite'),
      minute  => fqdn_rand(60, 'gitolite'),
    }
  } else {
    cron{'fetch gitolite repos upstream':
      ensure => 'absent',
    }
  }
}

