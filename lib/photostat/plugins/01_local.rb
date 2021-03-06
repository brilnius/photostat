module Photostat

  class Local < Plugins::Base
    include OSUtils
    include FileUtils

    help_text "Manages your local photos repository"

    exposes :config, "Configures your local database, repository path and Flickr login"
    exposes :import, "Imports images from a directory path (recursively) to your Photostat repository"

    def activate!
      unless @activated
        @db = Photostat::DB.instance
        Photostat::DB.migrate!
        @activated = true
      end
    end

    def import
      opts = Trollop::options do
        opt :path, "Local path to import", :required => true, :type => :string, :short => "-p"
        opt :tags, "List of tags to classify imported pictures", :type => :strings
        opt :visibility, "Choices are 'private', 'protected' and 'public'", :required => true, :type => :string
        opt :move, "Move, instead of copy (better performance, defaults to false, careful)", :type => :boolean
        opt :link, "Make symbolic links, instead of copy/move (defaults to false)", :type => :boolean
        opt :keeppath, "Keep relative path from given directory", :type => :string
        opt :keepname, "Keep the original filename", :type => :boolean
        opt :exclude, "List of patterns for file to exclude", :type => :strings
        opt :excludedir, "List of patterns for directories to exclude", :type => :strings
        opt :dry, "Just fake it and print the resulting files", :type => :boolean
      end

      Trollop::die :path, "must be a valid directory" unless File.directory? opts[:path]
      Trollop::die :visibility, "is invalid. Choices are: private, protected and public" unless ['private', 'protected', 'public'].member? opts[:visibility]
      opts[:tags] ||= []

      activate!

      source = File.expand_path opts[:path] 
      config = Photostat.config

      not_match = nil
      if not opts[:exclude].nil?
        not_match = Regexp.new('(' + opts[:exclude].join(')|(') + ')')
      end
      not_match_dir = nil
      if not opts[:excludedir].nil?
        not_match_dir = Regexp.new('(' + opts[:excludedir].join(')|(') + ')')
      end
      files = files_in_dir(source, :match => /(.jpe?g|.mov)$/i, :absolute? => true,
        :not_match => not_match, :not_match_dir=> not_match_dir)
      count, total = 0, files.length
      puts

      interrupted = false
      trap("INT") { interrupted = true }

      files.each do |fpath|        
        break if interrupted
        count += 1

        STDOUT.print "\r - processed: #{count} / #{total}"
        STDOUT.flush

        if fpath =~ /.jpe?g/i
          type = 'jpg'
          exif = EXIFR::JPEG.new fpath
          dt = (exif.date_time || File.mtime(fpath)).getgm
        else
          type = 'mov'
          dt = File.mtime(fpath).getgm
        end

        md5 = partial_file_md5 fpath
        uid = dt.strftime("%Y%m%d%H%M%S") + "-" + md5[0,6] + "." + type

        local_dir  = type == 'jpg' ? dt.strftime("%Y-%m") : 'movies'
        local_path = File.join(local_dir, uid)
        dest_dir   = File.join(config[:repository_path], local_dir)
        dest_path  = File.join(config[:repository_path], local_path)

        photo = @db[:photos].where(:uid => uid).first
        photo_id = photo ? photo[:id] : nil
        
        # Keep original relative path, if required
        # Find base path (keeppath arg value) in the file path
        orig_path = nil
        if not opts[:keeppath].nil?
          lookup_pairs = [
                   [fpath,                   opts[:keeppath]],
                   [fpath,                   File.expand_path(opts[:keeppath])],
                   [File.expand_path(fpath), opts[:keeppath]],
                   [File.expand_path(fpath), File.expand_path(opts[:keeppath])],
                  ]
          lookup_pairs.each do |filepath, basepath|
            if File.dirname(filepath) =~ /^#{Regexp.escape(basepath)}/
              orig_path = $'
              break
            end
          end
          if orig_path.nil?
            puts "Could not build relative path of #{fpath} from #{opts[:keeppath]}"
          else
            # Remove heading/trailing slashes
            orig_path = orig_path.gsub(/^[\/\\]+/,'').gsub(/[\/\\]+$/,'')
          end
        end
        
        # Keep original file name, if required
        orig_name = nil
        orig_name = File.basename(fpath) if opts[:keepname]      

        unless photo || opts[:dry]
          photo_id = @db[:photos].insert(
            :uid => uid,
            :type => type,
            :local_path => local_path,
            :visibility => opts[:visibility],
            :has_flickr_upload => false,
            :orig_path => orig_path,
            :orig_name => orig_name,
            :created_at => dt,
          )
        end

        opts[:tags].each do |name|
          next if opts[:dry]
          next unless @db[:tags].where(:name => name, :photo_id => photo_id).empty?
          @db[:tags].insert(:name => name, :photo_id => photo_id)
        end

        next if File.exists? dest_path
        next if File.expand_path(dest_path) == File.expand_path(fpath)

        unless opts[:dry]
          mkdir_p dest_dir
          if opts[:link]
            begin
              wd = getwd
              chdir File.dirname(dest_path)
              ln_s File.expand_path(fpath), File.basename(dest_path)
              chdir wd
            rescue Errno::EPERM,NotImplementedError => e
              puts "symlink is not implemented, --link flag cannot be used"
              exit 1
            end
          elsif opts[:move]
            mv fpath, dest_path
          else
            cp fpath, dest_path
          end
        end
      end

      if !files or files.length == 0
        puts " - nothing to do"
      end
      
      if interrupted
        puts
        puts " - interrupted by user" 
        puts
        exit 0
      end

      puts
    end

    def config
      puts
      config_file = File.expand_path "~/.photostat"

      config = {}
      config = YAML::load(File.read config_file) if File.exists? config_file

      config[:repository_path] ||= "~/Photos"
      config[:repository_path] = input(
        "Wanted location for your Photostat repository", 
        :dir? => true, :default => config[:repository_path])
      config[:repository_path] = File.expand_path(config[:repository_path])

      puts
      unless File.directory? config[:repository_path]
        Dir.mkdir config[:repository_path]
        puts " >>>> repository #{config[:repository_path]} created"
      end

      File.open(config_file, 'w') do |fh|
        fh.write(YAML::dump(config))
        puts " >>>> generated ~/.photostat config"
      end  

      puts
    end

  end

end
