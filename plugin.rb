# frozen_string_literal: true

# name: discourse-webp-watermark
# about: Convert uploaded images to WebP and apply watermarks automatically with high performance.
# version: 1.1.0
# authors: jikejun.com
# url: https://github.com/JiKeJun/discourse-webp-watermark
# required_version: 2.7.0

require "net/http"
require "uri"
require "digest/sha1"
require "fileutils"

enabled_site_setting :webp_conversion_enabled

after_initialize do
  module ::DiscourseWebpWatermark
    # Helper to resolve watermark path (local files, absolute, relative, or URLs)
    def self.watermark_local_path
      url = SiteSetting.webp_watermark_image
      return nil if url.blank?

      if url.start_with?("/")
        # Local relative path checks (e.g. /uploads/...)
        public_path = Rails.root.join("public", url.sub(/\A\//, ""))
        return public_path.to_s if File.exist?(public_path)
      end

      if url.start_with?("http://", "https://")
        dir = Rails.root.join("tmp", "webp_watermark_cache")
        FileUtils.mkdir_p(dir) unless Dir.exist?(dir)

        ext = File.extname(URI.parse(url).path)
        ext = ".png" if ext.blank?
        local_file = File.join(dir, "#{Digest::SHA1.hexdigest(url)}#{ext}")

        # Cache downloaded watermark for 1 day
        if File.exist?(local_file) && File.mtime(local_file) > 1.day.ago
          return local_file
        end

        begin
          uri = URI.parse(url)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = (uri.scheme == "https")
          http.open_timeout = 5
          http.read_timeout = 5
          
          response = http.get(uri.request_uri)
          if response.code == "200"
            File.open(local_file, "wb") { |f| f.write(response.body) }
            return local_file
          end
        rescue => e
          Rails.logger.error("WebP watermark plugin failed to download watermark from #{url}: #{e.message}")
          return local_file if File.exist?(local_file)
        end
      else
        # Fallback if it's an absolute path
        return url if File.exist?(url)
      end

      nil
    end
  end

  module ::DiscourseWebpWatermark::UploadCreatorExtension
    def create_for(user_id)
      begin
        if SiteSetting.webp_conversion_enabled && should_convert_to_webp?
          convert_and_watermark_to_webp!
        end
      rescue => e
        Rails.logger.error("WebP watermark plugin error in create_for: #{e.message}\n#{e.backtrace.join("\n")}")
      end
      super(user_id)
    end

    # Prevent double conversion/optimization in the standard Discourse pipeline
    def convert_to_jpeg!
      return if @converted_to_webp
      super
    end

    def should_alter_quality?
      return false if @converted_to_webp
      super
    end

    def should_optimize?
      return false if @converted_to_webp
      super
    end

    private

    def should_convert_to_webp?
      return false if @opts[:external_upload_too_big]

      extract_image_info! unless @image_info
      return false unless @image_info

      # Skip animated images (such as animated GIFs/WebPs) to minimize server load
      return false if animated?

      # Skip SVG and ICO (favicon)
      return false if @image_info.type == :svg
      return false if @image_info.type == :ico

      # Exclude administrative files, site logo/branding assets, and other system images
      exclude_types = %w[badge_image branding category_background category_background_dark category_logo category_logo_dark group_flair]
      return false if exclude_types.include?(@opts[:type])
      return false if @opts[:for_site_setting]

      # Supported formats
      supported_formats = %i[png jpeg jpg webp heif heic bmp tiff]
      supported_formats.include?(@image_info.type)
    end

    def should_watermark?
      return false unless SiteSetting.webp_watermark_enabled

      # Exclude user avatars, profile backgrounds, card backgrounds, custom emojis from watermarks
      exclude_watermark_types = %w[avatar profile_background card_background custom_emoji]
      return false if exclude_watermark_types.include?(@opts[:type])

      # Validate minimum image size to prevent watermarking tiny icons/avatars
      w, h = @image_info.size
      if w && h
        return false if w < SiteSetting.webp_watermark_min_width || h < SiteSetting.webp_watermark_min_height
      end

      # Ensure watermark file exists
      watermark_file = ::DiscourseWebpWatermark.watermark_local_path
      return false if watermark_file.blank?

      true
    end

    def convert_and_watermark_to_webp!
      webp_tempfile = Tempfile.new(%w[image .webp])
      from = @file.path
      to = webp_tempfile.path

      OptimizedImage.ensure_safe_paths!(from, to)

      # Build ImageMagick unified command
      command = ["magick", from, "-auto-orient"]

      if should_watermark?
        watermark_file = ::DiscourseWebpWatermark.watermark_local_path
        opacity = SiteSetting.webp_watermark_opacity.to_f / 100.0
        opacity = 0.5 if opacity <= 0.0 || opacity > 1.0

        position = SiteSetting.webp_watermark_position
        
        # Calculate dynamic watermark width (15% of the uploaded image width, clamped 40px to 800px)
        w, _h = @image_info.size
        w ||= 800
        watermark_width = (w * 0.15).to_i
        watermark_width = 40 if watermark_width < 40
        watermark_width = 800 if watermark_width > 800

        # Calculate dynamic margin (2% of the uploaded image width, clamped 10px to 50px)
        margin = (w * 0.02).to_i
        margin = 10 if margin < 10
        margin = 50 if margin > 50

        geometry = (position == "Center") ? "+0+0" : "+#{margin}+#{margin}"

        # Single composite overlay with customizable opacity and dynamic scaling
        command += [
          "(", watermark_file, "-resize", "#{watermark_width}x", "-channel", "A", "-evaluate", "multiply", opacity.to_s, ")",
          "-gravity", position,
          "-geometry", geometry,
          "-composite"
        ]
      end

      # Strip EXIF metadata for privacy and extra file size reduction
      command += ["-strip"]

      # Output format & quality compression
      quality = SiteSetting.webp_quality
      quality = 80 if quality <= 0 || quality > 100
      command += ["-quality", quality.to_s, to]

      # Execute single command with timeout protection
      Discourse::Utils.execute_command(
        *command,
        failure_message: "WebP Watermark plugin failed to convert image",
        timeout: 20
      )

      # Switch file references to the new optimized webp tempfile
      @file.respond_to?(:close!) ? @file.close! : @file.close
      @file = webp_tempfile
      @converted_to_webp = true

      # Update the original filename so it saves with .webp extension
      ext = File.extname(@filename)
      if ext.present?
        @filename = @filename.sub(/#{Regexp.escape(ext)}\z/i, ".webp")
      else
        @filename = "#{@filename}.webp"
      end

      extract_image_info!
    end
  end

  ::UploadCreator.prepend(::DiscourseWebpWatermark::UploadCreatorExtension)
end

