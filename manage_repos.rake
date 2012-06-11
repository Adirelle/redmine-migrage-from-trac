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
      project.repositories.each do |repo|

        # Fetch identifier
        identifier = repo.identifier
        if !identifier || identifier.strip == ""
          if repo.is_default?
            identifier = project.identifier
          else
            puts "#{project.identifier}: invalid repository identifier: #{identifier}"
            next
          end
        end

        # Ignore repositories with unhandled SCMs
        begin
          adapter = SCMRepoAdapter.const_get(repo.scm_name)
        rescue
          puts "#{identifier}: ignoring SCM #{repo.scm_name}"
          next
        end

        url = repo.url
        path = adapter.path_from_url(url) or next

        # Ignore non-standard paths
        unless path == File.join(adapter::ROOT, identifier)
          puts "#{identifier}: ignoring repository with non-standard path: #{path}, should be: #{File.join(adapter::ROOT, identifier)}"
          next
        end

        # Create the repository if need be
        unless File.exists?(path) && File.directory?(path)
          if system "#{adapter::CREATE_COMMAND} #{path}" then
            puts "#{identifier}: created #{repo.scm_name} repository in #{path}"
          else
            puts "#{identifier}: failed to create repository"
            next
          end
        end

        # Check ownership and permissions
        fstat = File.stat(path)
        unless fstat.uid == uid && fstat.gid == gid && (fstat.mode & 0777) == 0770
          puts "#{identifier}: fixing repository ownership and permissions"
          files = []
          Find.find(path) { |f| files << f unless File.symlink?(f) }
          File.chown uid, gid, *files or die "Could not chown some files of repository #{identifier} !"
          File.chmod 0770, *files or die "Coult not chmod some files or repository #{identifier} !"
        end

      end

    end

  end

end
# vim:expandtab:sw=2 ts=2
