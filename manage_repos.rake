# Copyright 2012 IRSTEA

require 'find'
require 'etc'

namespace :redmine do
  desc 'Manage repositories'
  task :manage_repos => :environment do |t, args|

    # Pseudo adapters
    module SCMRepoAdapter

      module Git
        CREATE_COMMAND = 'git init --bare --shared=group'
        ROOT = '/var/lib/git'
        def self.path_from_url(url) url =~ /^(\/.*)$/ ? $1 : nil end
        def self.url_from_path(path) path end
      end

      module Subversion
        CREATE_COMMAND = 'svnadmin create'
        ROOT = '/var/lib/svn'
        def self.path_from_url(url) url =~ /^(?:file:\/\/)?(\/.+)$/ ? $1 : nil end
        def self.url_from_path(path) "file://#{path}" end
      end

    end

    # UID and GID of repository
    uid = Etc.getpwnam('redmine').uid
    gid = Etc.getgrnam('www-data').gid

    # Check each active projects
    Project.active.each do |project|

      # Ignore projects without defined repository
      repo = project.repository or next

      identifier = project.identifier

      # Ignore projects with unhandled SCMs
      begin
        adapter = SCMRepoAdapter.const_get(repo.scm_name)
      rescue
        puts "#{identifier}: ignoring SCM #{repo.scm_name}"
        next
      end

      url = repo.url

      if url.strip.upcase == 'AUTO'
        # We should create a local repository

        # Define path and URL
        path = adapter::ROOT + '/' + project.identifier
        url = adapter.url_from_path(path)

        # Create the repository unless it exists
        unless File.exists?(path)
          if system "#{adapter::CREATE_COMMAND} #{path}" then
            puts "#{identifier}: created #{repo.scm_name} repository in #{path}"
          else
            puts "#{identifier}: failed to create repository"
            next
          end
        else
          puts "#{identifier}: using existing repository in #{path}"
        end

        # Update the repository data
        repo.url = url
        repo.save and puts "#{identifier}: repository URL set to #{url}"

      else
        # Checking defined repository, if it is local
        path = adapter.path_from_url(url) or next
      end

      # Check the repository is a directory
      unless File.exists?(path) && File.directory?(path)
        puts "#{identifier}: repository #{path} does not exist or is not a directory"
        next
      end

      # Check ownership and permissions
      fstat = File.stat(path)
      unless fstat.uid == uid && fstat.gid == gid && (fstat.mode & 0777) == 0770
        puts "#{identifier}: fixing repository ownership and permissions"
        files = []
        Find.find(path) { |f| files << f unless File.symlink?(f) }
        File.chown uid, gid, *files or die "bla !"
        File.chmod 0770, *files or die "bla !"
      end

    end

  end
end
# vim:expandtab:sw=2 ts=2
