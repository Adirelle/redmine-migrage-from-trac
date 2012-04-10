# Redmine - project management software
# Copyright (C) 2006-2011  Jean-Philippe Lang
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

require 'active_record'
require 'iconv'
require 'pp'

namespace :redmine do
  desc 'Trac migration script'
  task :migrate_from_trac, [:directory, :adapter, :project_id, :encoding, :db_host, :db_port, :db_name, :db_schema, :db_username, :db_password] => :environment do |t, args|

    module TracMigrate
        TICKET_MAP = []

        DEFAULT_STATUS = IssueStatus.default
        assigned_status = IssueStatus.find_by_position(2)
        resolved_status = IssueStatus.find_by_position(3)
        feedback_status = IssueStatus.find_by_position(4)
        closed_status = IssueStatus.find :first, :conditions => { :is_closed => true }
        STATUS_MAPPING = {'new' => DEFAULT_STATUS,
                          'reopened' => feedback_status,
                          'assigned' => assigned_status,
                          'closed' => closed_status
                          }

        priorities = IssuePriority.all
        DEFAULT_PRIORITY = priorities[0]
        PRIORITY_MAPPING = {'lowest' => priorities[0],
                            'low' => priorities[0],
                            'normal' => priorities[1],
                            'high' => priorities[2],
                            'highest' => priorities[3],
                            # ---
                            'trivial' => priorities[0],
                            'minor' => priorities[1],
                            'major' => priorities[2],
                            'critical' => priorities[3],
                            'blocker' => priorities[4]
                            }

        TRACKER_BUG = Tracker.find_by_position(1)
        TRACKER_FEATURE = Tracker.find_by_position(2)
        DEFAULT_TRACKER = TRACKER_BUG
        TRACKER_MAPPING = {'defect' => TRACKER_BUG,
                           'enhancement' => TRACKER_FEATURE,
                           'task' => TRACKER_FEATURE,
                           'patch' =>TRACKER_FEATURE
                           }

        roles = Role.find(:all, :conditions => {:builtin => 0}, :order => 'position ASC')
        manager_role = roles[0]
        developer_role = roles[1]
        DEFAULT_ROLE = roles.last
        ROLE_MAPPING = {'admin' => manager_role,
                        'developer' => developer_role
                        }

      class ::Time
        class << self
          alias :real_now :now
          def now
            real_now - @fake_diff.to_i
          end
          def fake(time)
            @fake_diff = real_now - time
            res = yield
            @fake_diff = 0
           res
          end
        end
      end

      class TracComponent < ActiveRecord::Base
        set_table_name :component
      end

      class TracTicketCustom < ActiveRecord::Base
        set_table_name :ticket_custom
      end

      class TracAttachment < ActiveRecord::Base
        set_table_name :attachment
        set_inheritance_column :none

        def time; Time.at(read_attribute(:time)) end

        def original_filename
          filename
        end

        def content_type
          ''
        end

        def exist?
          File.file? trac_fullpath
        end

        def open
          File.open("#{trac_fullpath}", 'rb') {|f|
            @file = f
            yield self
          }
        end

        def read(*args)
          @file.read(*args)
        end

        def description
          read_attribute(:description).to_s.slice(0,255)
        end

      private
        def trac_fullpath
          attachment_type = read_attribute(:type)
          trac_file = filename.gsub( /[^a-zA-Z0-9\-_\.!~*']/n ) {|x| sprintf('%%%02X', x[0]) }
          "#{TracMigrate.trac_attachments_directory}/#{attachment_type}/#{id}/#{trac_file}"
        end
      end

      class TracMilestone < ActiveRecord::Base
        set_table_name :milestone

        has_many :attachments, :class_name => "TracAttachment",
                               :finder_sql => "SELECT DISTINCT attachment.* FROM #{TracMigrate::TracAttachment.table_name}" +
                                              " WHERE #{TracMigrate::TracAttachment.table_name}.type = 'milestone'" +
                                              ' AND #{TracMigrate::TracAttachment.table_name}.id = \'#{TracMigrate::TracAttachment.connection.quote_string(name.to_s)}\''

        # If this attribute is set a milestone has a defined target timepoint
        def due
          if read_attribute(:due) && read_attribute(:due) > 0
            Time.at(read_attribute(:due)).to_date
          else
            nil
          end
        end
        # This is the real timepoint at which the milestone has finished.
        def completed
          if read_attribute(:completed) && read_attribute(:completed) > 0
            Time.at(read_attribute(:completed)).to_date
          else
            nil
          end
        end

        def description
          # Attribute is named descr in Trac v0.8.x
          has_attribute?(:descr) ? read_attribute(:descr) : read_attribute(:description)
        end
      end

      class TracTicket < ActiveRecord::Base
        set_table_name :ticket
        set_inheritance_column :none

        # ticket changes: only migrate status changes and comments
        has_many :changes, :class_name => "TracTicketChange", :foreign_key => :ticket
        has_many :attachments, :class_name => "TracAttachment",
                               :finder_sql => "SELECT DISTINCT attachment.* FROM #{TracMigrate::TracAttachment.table_name}" +
                                              " WHERE #{TracMigrate::TracAttachment.table_name}.type = 'ticket'" +
                                              ' AND #{TracMigrate::TracAttachment.table_name}.id = \'#{TracMigrate::TracAttachment.connection.quote_string(id.to_s)}\''
        has_many :customs, :class_name => "TracTicketCustom", :foreign_key => :ticket

        def ticket_type
          read_attribute(:type)
        end

        def summary
          read_attribute(:summary).blank? ? "(no subject)" : read_attribute(:summary)
        end

        def description
          read_attribute(:description).blank? ? summary : read_attribute(:description)
        end

        def time; Time.at(read_attribute(:time)) end
        def changetime; Time.at(read_attribute(:changetime)) end
      end

      class TracTicketChange < ActiveRecord::Base
        set_table_name :ticket_change

        def time; Time.at(read_attribute(:time)) end
      end

      TRAC_WIKI_PAGES = %w(InterMapTxt InterTrac InterWiki RecentChanges SandBox TracAccessibility TracAdmin TracBackup TracBrowser TracCgi TracChangeset \
                           TracEnvironment TracFastCgi TracGuide TracImport TracIni TracInstall TracInterfaceCustomization \
                           TracLinks TracLogging TracModPython TracNotification TracPermissions TracPlugins TracQuery \
                           TracReports TracRevisionLog TracRoadmap TracRss TracSearch TracStandalone TracSupport TracSyntaxColoring TracTickets \
                           TracTicketsCustomFields TracTimeline TracUnicode TracUpgrade TracWiki WikiDeletePage WikiFormatting \
                           WikiHtml WikiMacros WikiNewPage WikiPageNames WikiProcessors WikiRestructuredText WikiRestructuredTextLinks \
                           PageTemplates TracFineGrainedPermissions TracNavigation TracWorkflow \
                           CamelCase TitleIndex)

      class TracWikiPage < ActiveRecord::Base
        set_table_name :wiki
        set_primary_key :name

        has_many :attachments, :class_name => "TracAttachment",
                               :finder_sql => "SELECT DISTINCT attachment.* FROM #{TracMigrate::TracAttachment.table_name}" +
                                      " WHERE #{TracMigrate::TracAttachment.table_name}.type = 'wiki'" +
                                      ' AND #{TracMigrate::TracAttachment.table_name}.id = \'#{TracMigrate::TracAttachment.connection.quote_string(id.to_s)}\''

        def self.columns
          # Hides readonly Trac field to prevent clash with AR readonly? method (Rails 2.0)
          super.select {|column| column.name.to_s != 'readonly'}
        end

        def time; Time.at(read_attribute(:time)) end
      end

      class TracPermission < ActiveRecord::Base
        set_table_name :permission
      end

      class TracSessionAttribute < ActiveRecord::Base
        set_table_name :session_attribute
      end

      def self.find_or_create_user(username, project_member = false)
        return User.anonymous if username.blank?

        u = User.find_by_login(username)
        if !u
          # Create a new user if not found
          mail = username[0,limit_for(User, 'mail')]
          if mail_attr = TracSessionAttribute.find_by_sid_and_name(username, 'email')
            mail = mail_attr.value
          end
          mail = "#{mail}@foo.bar" unless mail.include?("@")

          name = username
          if name_attr = TracSessionAttribute.find_by_sid_and_name(username, 'name')
            name = name_attr.value
          end
          name =~ (/(.*)(\s+\w+)?/)
          fn = $1.strip
          ln = ($2 || '-').strip

          u = User.new :mail => mail.gsub(/[^-@a-z0-9\.]/i, '-'),
                       :firstname => fn[0, limit_for(User, 'firstname')],
                       :lastname => ln[0, limit_for(User, 'lastname')]

          u.login = username[0,limit_for(User, 'login')].gsub(/[^a-z0-9_\-@\.]/i, '-')
          u.password = 'trac'
          u.admin = true if TracPermission.find_by_username_and_action(username, 'admin')
          # finally, a default user is used if the new user is not valid
          u = User.find(:first) unless u.save
        end
        # Make sure he is a member of the project
        if project_member && !u.member_of?(@target_project)
          role = DEFAULT_ROLE
          if u.admin
            role = ROLE_MAPPING['admin']
          elsif TracPermission.find_by_username_and_action(username, 'developer')
            role = ROLE_MAPPING['developer']
          end
          Member.create(:user => u, :project => @target_project, :roles => [role])
          u.reload
        end
        u
      end

      # Basic wiki syntax conversion
      def self.convert_wiki_text(text)
        # Encode it
        text = encode(text)

        # Protect code blocks
        code_blocks = []
        text = text.gsub(/\{\{\{(?:\s*#!(\w+))?\s*(.*?)\s*\}\}\}/m) { |s| code_blocks << [$1, $2] ; '###CODE###' }

        # Titles
        text = text.gsub(/^(\=+)\s(.+)\s(\=+)/) {|s| "\nh#{$1.length}. #{$2}\n"}
        # External Links
        text = text.gsub(/\[(http\S+)\s+(.+?)\]/, '"\2":\1')
        # Attachments links
        text = text.gsub(/attachment:(wiki|milestone|ticket):[^:]+:(\S+?)/, 'attachment:\2')
        text = text.gsub(/\[attachment:(\S+)\s+(.*?)\]/) {|s| "#{$2}: attachment:#{sanitize_attachment_filename($1)}"}
        text = text.gsub(/\[attachment:(.+?)\]/) {|s| "attachment:#{sanitize_attachment_filename($1)}"}
        text = text.gsub(/attachment:(\S+)/) {|s| "attachment:#{sanitize_attachment_filename($1)}"}
        # Ticket links:
        #      [ticket:234 Text],[ticket:234 This is a test]
        text = text.gsub(/\[ticket:(\d+)\s+(.+?)\]/, '"\2":/issues/show/\1')
        #      ticket:1234
        #      #1 is working cause Redmine uses the same syntax.
        text = text.gsub(/ticket:(\d+)/, '#\1')
        # Milestone links:
        #      [milestone:"0.1.0 Mercury" Milestone 0.1.0 (Mercury)]
        #      The text "Milestone 0.1.0 (Mercury)" is not converted,
        #      cause Redmine's wiki does not support this.
        text = text.gsub(/\[milestone:"(.+?)"\s+(.+?)\]/, 'version:"\1"')
        #      [milestone:"0.1.0 Mercury"]
        text = text.gsub(/\[milestone:"(.+?)"\]/, 'version:"\1"')
        #      [milestone:0.1.0]
        text = text.gsub(/\[milestone:(\S+)\]/, 'version:\1')
        #      milestone:"0.1.0 Mercury"
        text = text.gsub(/milestone:"(.+?)"/, 'version:"\1"')
        #      milestone:0.1.0
        text = text.gsub(/milestone:(\S+)/, 'version:\1')
        # Internal Links
        text = text.gsub(/\[\[BR\]\]/, "\n") # This has to go before the rules below
        #      ["Some page"]
        text = text.gsub(/\[\"(.+)\"\]/) {|s| "[[#{Wiki.titleize($1)}]]"}
        #      [wiki:"Some page"]
        text = text.gsub(/\[wiki:\"(.+?)\"\]/) {|s| "[[#{Wiki.titleize($1)}]]"}
        #      [wiki:SomePage Some text]
        text = text.gsub(/\[wiki:(\w+)\s+(.+?)\]/) {|s| "[[#{Wiki.titleize($1)}|#{$2}]]"}
        #      [CamelCase Some text]
        text = text.gsub(/\[([A-Z][a-z]+[A-Z][a-zA-Z]+)\s+(.+?)\]/) {|s| "[[#{Wiki.titleize($1)}|#{$2}]]"}
        #      wiki:CamelCase
        text = text.gsub(/wiki:([A-Z][a-z]+[A-Z][a-zA-Z]+)/, '[[\1]]')

        # Protect already converted links
        links = []
        text = text.gsub(/\[\[.*?\]\]/) { |s| links << s ; '###LINK###' }

        # Links to pages UsingJustWikiCaps
        text = text.gsub(/([^!]|^)(^| )([A-Z][a-z]+[A-Z][a-zA-Z]+)/, '\\1\\2[[\3]]')
        # Normalize things that were supposed to not be links
        # like !NotALink
        text = text.gsub(/(^| )!([A-Z][A-Za-z]+)/, '\1\2')
        # Revisions links
        #      [15]
        text = text.gsub(/\[(\d+)\]/, 'r\1')
        #      changeset:15
        text = text.gsub(/changeset:(\d+)/, 'r\1')
        # Ticket number re-writing
        text = text.gsub(/#(\d+)/) do |s|
          if $1.length < 10
#            TICKET_MAP[$1.to_i] ||= $1
            "\##{TICKET_MAP[$1.to_i] || $1}"
          else
            s
          end
        end

        # Restore links
        text = text.gsub('###LINK###') { |s| links.shift }

        # Highlighting
        text = text.gsub(/'''''([^\s])/, '_*\1')
        text = text.gsub(/([^\s])'''''/, '\1*_')
        text = text.gsub(/'''/, '*')
        text = text.gsub(/''/, '_')
        text = text.gsub(/__/, '+')
        text = text.gsub(/~~/, '-')
        text = text.gsub(/`/, '@')
        text = text.gsub(/,,/, '~')
        # Lists
        text = text.gsub(/^([ ]+)\* /) {|s| '*' * $1.length + " "}

        # Restore and convert code blocks
        text = text.gsub('###CODE###') do |s|
          shebang, block = code_blocks.shift
          if shebang
            "<code class=\"#{shebang}\"><pre>#{block}</pre></code>"
          else
            "<pre>#{block}</pre>"
          end
        end

        text
      end

      def self.sanitize_attachment_filename(filename)
        filename.gsub(/^.*(\\|\/)/, '').gsub(/[^\w\.\-]/,'_')
      end

      def self.migrate_attachments(tracContainer, container)
        count = 0
        tracContainer.attachments.each do |attachment|
          next if attachment.nil?
          mangled_filename = sanitize_attachment_filename(attachment.filename)
          next if container.attachments.find_by_filename(mangled_filename)
          attachment.open {
            a = Attachment.new :created_on => attachment.time
            a.file = attachment
            a.author = find_or_create_user(attachment.author)
            a.description = attachment.description
            a.container = container
            count += 1 if a.save
          }
        end
        count
      end

      def self.migrate
        establish_connection

        # Quick database test
        TracComponent.count

        migrated_components = 0
        migrated_milestones = 0
        migrated_milestone_attachments = 0
        migrated_tickets = 0
        migrated_custom_values = 0
        migrated_ticket_attachments = 0
        migrated_wiki_edits = 0
        migrated_wiki_attachments = 0

        #Wiki system initializing...
        @target_project.wiki.destroy if @target_project.wiki
        @target_project.reload
        wiki = Wiki.new(:project => @target_project, :start_page => 'WikiStart')
        wiki_edit_count = 0

        # Components
        print "Migrating components"
        issues_category_map = {}
        TracComponent.find(:all).each do |component|
          print '.'
          STDOUT.flush
          c = IssueCategory.new :project => @target_project,
                                :name => encode(component.name[0, limit_for(IssueCategory, 'name')])
          next unless c.save
          issues_category_map[component.name] = c
          migrated_components += 1
        end
        puts

        # Milestones
        print "Migrating milestones"
        version_map = {}
        TracMilestone.find(:all).each do |milestone|
          print '.'
          STDOUT.flush
          # First we try to find the wiki page...
          wiki_page_title = "Version" + Wiki.titleize(milestone.name.to_s)
          p = wiki.find_or_new_page(wiki_page_title)
          p.content = WikiContent.new(:page => p) if p.new_record?
          p.content.text = milestone.description.to_s
          p.content.author = find_or_create_user('trac')
          p.content.comments = 'Milestone'
          p.save

          v = Version.new :project => @target_project,
                          :name => encode(milestone.name[0, limit_for(Version, 'name')]),
                          :description => nil,
                          :wiki_page_title => wiki_page_title,
                          :effective_date => milestone.completed

          next unless v.save
          version_map[milestone.name] = v
          migrated_milestones += 1
          migrated_milestone_attachments += migrate_attachments(milestone, v)
        end
        puts

        # Custom fields
        # TODO: read trac.ini instead
        print "Migrating custom fields"
        custom_field_map = {}
        TracTicketCustom.find_by_sql("SELECT DISTINCT name FROM #{TracTicketCustom.table_name}").each do |field|
          print '.'
          STDOUT.flush
          # Redmine custom field name
          field_name = encode(field.name[0, limit_for(IssueCustomField, 'name')]).humanize
          # Find if the custom already exists in Redmine
          f = IssueCustomField.find_by_name(field_name)
          # Or create a new one
          f ||= IssueCustomField.create(:name => encode(field.name[0, limit_for(IssueCustomField, 'name')]).humanize,
                                        :field_format => 'string')

          next if f.new_record?
          f.trackers = Tracker.find(:all)
          f.projects << @target_project
          custom_field_map[field.name] = f
        end
        puts

        # Trac 'resolution' field as a Redmine custom field
        r = IssueCustomField.find(:first, :conditions => { :name => "Resolution" })
        r = IssueCustomField.new(:name => 'Resolution',
                                 :field_format => 'list',
                                 :is_filter => true) if r.nil?
        r.trackers = Tracker.find(:all)
        r.projects << @target_project
        r.possible_values = (r.possible_values + %w(fixed invalid wontfix duplicate worksforme)).flatten.compact.uniq
        r.save!
        custom_field_map['resolution'] = r

        # Tickets
        print "Migrating tickets"
          TracTicket.find_each(:batch_size => 200) do |ticket|
          print '.'
          STDOUT.flush
          i = Issue.new :project => @target_project,
                          :subject => encode(ticket.summary[0, limit_for(Issue, 'subject')]),
                          :description => convert_wiki_text(ticket.description),
                          :priority => PRIORITY_MAPPING[ticket.priority] || DEFAULT_PRIORITY,
                          :created_on => ticket.time
          i.author = find_or_create_user(ticket.reporter)
          i.category = issues_category_map[ticket.component] unless ticket.component.blank?
          i.fixed_version = version_map[ticket.milestone] unless ticket.milestone.blank?
          i.status = STATUS_MAPPING[ticket.status] || DEFAULT_STATUS
          i.tracker = TRACKER_MAPPING[ticket.ticket_type] || DEFAULT_TRACKER
          i.id = ticket.id unless Issue.exists?(ticket.id)
          next unless Time.fake(ticket.changetime) { i.save }
          TICKET_MAP[ticket.id] = i.id
          migrated_tickets += 1

          # Owner
          unless ticket.owner.blank?
            i.assigned_to = find_or_create_user(ticket.owner, true)
            Time.fake(ticket.changetime) { i.save }
          end

          # Comments and status/resolution changes
          ticket.changes.group_by(&:time).each do |time, changeset|
            status_change = changeset.select {|change| change.field == 'status'}.first
            resolution_change = changeset.select {|change| change.field == 'resolution'}.first
            comment_change = changeset.select {|change| change.field == 'comment'}.first

            n = Journal.new :notes => (comment_change ? convert_wiki_text(comment_change.newvalue) : ''),
                            :created_on => time
            n.user = find_or_create_user(changeset.first.author)
            n.journalized = i
            if status_change &&
                 STATUS_MAPPING[status_change.oldvalue] &&
                 STATUS_MAPPING[status_change.newvalue] &&
                 (STATUS_MAPPING[status_change.oldvalue] != STATUS_MAPPING[status_change.newvalue])
              n.details << JournalDetail.new(:property => 'attr',
                                             :prop_key => 'status_id',
                                             :old_value => STATUS_MAPPING[status_change.oldvalue].id,
                                             :value => STATUS_MAPPING[status_change.newvalue].id)
            end
            if resolution_change
              n.details << JournalDetail.new(:property => 'cf',
                                             :prop_key => custom_field_map['resolution'].id,
                                             :old_value => resolution_change.oldvalue,
                                             :value => resolution_change.newvalue)
            end
            n.save unless n.details.empty? && n.notes.blank?
          end

          # Attachments
          migrated_ticket_attachments += migrate_attachments(ticket, i)

          # Custom fields
          custom_values = ticket.customs.inject({}) do |h, custom|
            if custom_field = custom_field_map[custom.name]
              h[custom_field.id] = custom.value
              migrated_custom_values += 1
            end
            h
          end
          if custom_field_map['resolution'] && !ticket.resolution.blank?
            custom_values[custom_field_map['resolution'].id] = ticket.resolution
          end
          i.custom_field_values = custom_values
          i.save_custom_field_values
        end

        # update issue id sequence if needed (postgresql)
        Issue.connection.reset_pk_sequence!(Issue.table_name) if Issue.connection.respond_to?('reset_pk_sequence!')
        puts

        # Wiki
        print "Migrating wiki"
        if wiki.save
          TracWikiPage.all(:select => 'name, MAX(version) AS version',
                           :conditions => [ 'name NOT IN (?)', TRAC_WIKI_PAGES ], # Do not migrate Trac manul wiki pages
                           :group => 'name').each do |page|
            print '.'
            STDOUT.flush
            wiki_edit_count += 1
            p = wiki.find_or_new_page(page.name)
            TracWikiPage.all(:conditions => [ 'name = ?', page.name ], :order => 'version').each do |rev|
              p.content = WikiContent.new(:page => p) if p.new_record?
              p.content.text = rev.text
              p.content.author = find_or_create_user(rev.author) unless rev.author.blank? || rev.author == 'trac'
              p.content.comments = rev.comment
              Time.fake(rev.time) { p.new_record? ? p.save : p.content.save }
              migrated_wiki_edits += 1
            end
            # Attachments
            migrated_wiki_attachments += migrate_attachments(page, p)
          end

          wiki.reload
          wiki.pages.each do |page|
            page.content.text = convert_wiki_text(page.content.text)
            Time.fake(page.content.updated_on) { page.content.save }
          end
        end
        puts

        puts
        puts "Components:      #{migrated_components}/#{TracComponent.count}"
        puts "Milestones:      #{migrated_milestones}/#{TracMilestone.count}"
        puts "Milestone files: #{migrated_milestone_attachments}/" + TracAttachment.count(:conditions => {:type => 'milestone'}).to_s
        puts "Tickets:         #{migrated_tickets}/#{TracTicket.count}"
        puts "Ticket files:    #{migrated_ticket_attachments}/" + TracAttachment.count(:conditions => {:type => 'ticket'}).to_s
        puts "Custom values:   #{migrated_custom_values}/#{TracTicketCustom.count}"
        puts "Wiki edits:      #{migrated_wiki_edits}/#{wiki_edit_count}"
        puts "Wiki files:      #{migrated_wiki_attachments}/" + TracAttachment.count(:conditions => {:type => 'wiki'}).to_s
      end

      def self.limit_for(klass, attribute)
        klass.columns_hash[attribute.to_s].limit
      end

      def self.encoding(charset)
        @ic = Iconv.new('UTF-8', charset)
      rescue Iconv::InvalidEncoding
        puts "Invalid encoding!"
        return false
      end

      def self.set_trac_directory(path)
        @@trac_directory = path
        raise "This directory doesn't exist!" unless File.directory?(path)
        raise "#{trac_attachments_directory} doesn't exist!" unless File.directory?(trac_attachments_directory)
        @@trac_directory
      rescue Exception => e
        puts e
        return false
      end

      def self.trac_directory
        @@trac_directory
      end

      def self.set_trac_adapter(adapter)
        return false if adapter.blank?
        raise "Unknown adapter: #{adapter}!" unless %w(sqlite sqlite3 mysql postgresql).include?(adapter)
        # If adapter is sqlite or sqlite3, make sure that trac.db exists
        raise "#{trac_db_path} doesn't exist!" if %w(sqlite sqlite3).include?(adapter) && !File.exist?(trac_db_path)
        @@trac_adapter = adapter
      rescue Exception => e
        puts e
        return false
      end

      def self.set_trac_db_host(host)
        return nil if host.blank?
        @@trac_db_host = host
      end

      def self.set_trac_db_port(port)
        return nil if port.to_i == 0
        @@trac_db_port = port.to_i
      end

      def self.set_trac_db_name(name)
        return nil if name.blank?
        @@trac_db_name = name
      end

      def self.set_trac_db_username(username)
        @@trac_db_username = username
      end

      def self.set_trac_db_password(password)
        @@trac_db_password = password
      end

      def self.set_trac_db_schema(schema)
        @@trac_db_schema = schema
      end

      mattr_reader :trac_directory, :trac_adapter, :trac_db_host, :trac_db_port, :trac_db_name, :trac_db_schema, :trac_db_username, :trac_db_password

      def self.trac_db_path; "#{trac_directory}/db/trac.db" end
      def self.trac_attachments_directory; "#{trac_directory}/attachments" end

      def self.target_project_identifier(identifier)
        project = Project.find_by_identifier(identifier)
        if !project
          # create the target project
          project = Project.new :name => identifier.humanize,
                                :description => ''
          project.identifier = identifier
          puts "Unable to create a project with identifier '#{identifier}'!" unless project.save
          # enable issues and wiki for the created project
          project.enabled_module_names = ['issue_tracking', 'wiki']
        else
          puts
          puts "This project already exists in your Redmine database."
          print "Are you sure you want to append data to this project ? [Y/n] "
          STDOUT.flush
          exit if STDIN.gets.match(/^n$/i)
        end
        project.trackers << TRACKER_BUG unless project.trackers.include?(TRACKER_BUG)
        project.trackers << TRACKER_FEATURE unless project.trackers.include?(TRACKER_FEATURE)
        @target_project = project.new_record? ? nil : project
        @target_project.reload
      end

      def self.connection_params
        if %w(sqlite sqlite3).include?(trac_adapter)
          {:adapter => trac_adapter,
           :database => trac_db_path}
        else
          {:adapter => trac_adapter,
           :database => trac_db_name,
           :host => trac_db_host,
           :port => trac_db_port,
           :username => trac_db_username,
           :password => trac_db_password,
           :schema_search_path => trac_db_schema
          }
        end
      end

      def self.establish_connection
        constants.each do |const|
          klass = const_get(const)
          next unless klass.respond_to? 'establish_connection'
          klass.establish_connection connection_params
        end
      end

    private
      def self.encode(text)
        @ic.iconv text
      rescue
        text
      end
    end

    puts
    if Redmine::DefaultData::Loader.no_data?
      puts "Redmine configuration need to be loaded before importing data."
      puts "Please, run this first:"
      puts
      puts "  rake redmine:load_default_data RAILS_ENV=\"#{ENV['RAILS_ENV']}\""
      exit
    end

    puts "WARNING: a new project will be added to Redmine during this process."
    print "Are you sure you want to continue ? [y/N] "
    STDOUT.flush
    break unless STDIN.gets.match(/^y$/i)
    puts

    def prompt(text, args, options = {}, &block)
      key = options[:key]
      default = options[:default] || ''
      if key
      arg = args[key]
      if arg && yield(arg)
        print "#{text}: #{arg}\n"
        STDOUT.flush
        return
      end
      end
      while true
      print "#{text} [#{default}]: "
      STDOUT.flush
      value = STDIN.gets.chomp!
      value = default if value.blank?
      break if yield value
      end
    end

    DEFAULT_PORTS = {'mysql' => 3306, 'postgresql' => 5432}

    prompt('Trac directory', args, :key => :directory) {|directory| TracMigrate.set_trac_directory directory.strip}
    prompt('Trac database adapter (sqlite, sqlite3, mysql, postgresql)', args, :default => 'sqlite', :key => :adapter) {|adapter| TracMigrate.set_trac_adapter adapter}
    unless %w(sqlite sqlite3).include?(TracMigrate.trac_adapter)
      prompt('Trac database host', args, :default => 'localhost', :key => :db_host) {|host| TracMigrate.set_trac_db_host host}
      prompt('Trac database port', args, :default => DEFAULT_PORTS[TracMigrate.trac_adapter], :key => :db_port) {|port| TracMigrate.set_trac_db_port port}
      prompt('Trac database name', args, :key => :db_name) {|name| TracMigrate.set_trac_db_name name}
      prompt('Trac database schema', args, :default => 'public', :key => :db_schema) {|schema| TracMigrate.set_trac_db_schema schema}
      prompt('Trac database username', args, :key => :db_username) {|username| TracMigrate.set_trac_db_username username}
      prompt('Trac database password', args, :key => :db_password) {|password| TracMigrate.set_trac_db_password password}
    end
    prompt('Trac database encoding', args, :default => 'UTF-8', :key => :encoding) {|encoding| TracMigrate.encoding encoding}
    prompt('Target project identifier', args, :key => :project_id) {|identifier| TracMigrate.target_project_identifier identifier}
    puts

    # Turn off email notifications
    Setting.notified_events = []

    TracMigrate.migrate
  end
end
# vi:expandtab:ts=2 sw=2
