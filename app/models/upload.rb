require "digest/sha1"
require_dependency "image_sizer"
require_dependency "file_helper"
require_dependency "validators/upload_validator"

class Upload < ActiveRecord::Base
  belongs_to :user

  has_many :post_uploads, dependent: :destroy
  has_many :posts, through: :post_uploads

  has_many :optimized_images, dependent: :destroy

  validates_presence_of :filesize
  validates_presence_of :original_filename

  validates_with ::Validators::UploadValidator

  def thumbnail(width = self.width, height = self.height)
    optimized_images.find_by(width: width, height: height)
  end

  def has_thumbnail?(width, height)
    thumbnail(width, height).present?
  end

  def create_thumbnail!(width, height, allow_animation = SiteSetting.allow_animated_thumbnails)
    return unless SiteSetting.create_thumbnails?
    thumbnail = OptimizedImage.create_for(self, width, height, allow_animation: allow_animation)
    if thumbnail
      optimized_images << thumbnail
      self.width = width
      self.height = height
      save!
    end
  end

  def destroy
    Upload.transaction do
      Discourse.store.remove_upload(self)
      super
    end
  end

  def extension
    File.extname(original_filename)
  end

  # options
  #   - content_type
  #   - origin
  def self.create_for(user_id, file, filename, filesize, options = {})
    sha1 = Digest::SHA1.file(file).hexdigest

    DistributedMutex.synchronize("upload_#{sha1}") do
      # do we already have that upload?
      upload = find_by(sha1: sha1)

      # make sure the previous upload has not failed
      if upload && upload.url.blank?
        upload.destroy
        upload = nil
      end

      # return the previous upload if any
      return upload unless upload.nil?

      # create the upload otherwise
      upload = Upload.new
      upload.user_id           = user_id
      upload.original_filename = filename
      upload.filesize          = filesize
      upload.sha1              = sha1
      upload.url               = ""
      upload.origin            = options[:origin][0...1000] if options[:origin]

      # deal with width & height for images
      upload = resize_image(filename, file, upload) if FileHelper.is_image?(filename)

      return upload unless upload.save

      # store the file and update its url
      url = Discourse.store.store_upload(file, upload, options[:content_type])
      if url.present?
        upload.url = url
        upload.save
      else
        upload.errors.add(:url, I18n.t("upload.store_failure", { upload_id: upload.id, user_id: user_id }))
      end

      # return the uploaded file
      upload
    end
  end

  def self.resize_image(filename, file, upload)
    begin
      if filename =~ /\.svg$/i
        svg = Nokogiri::XML(file).at_css("svg")
        width, height = svg["width"].to_i, svg["height"].to_i
        if width == 0 || height == 0
          upload.errors.add(:base, I18n.t("upload.images.size_not_found"))
        else
          upload.width, upload.height = ImageSizer.resize(width, height)
        end
      else
        # fix orientation first
        Upload.fix_image_orientation(file.path)
        # retrieve image info
        image_info = FastImage.new(file, raise_on_failure: true)
          # compute image aspect ratio
        upload.width, upload.height = ImageSizer.resize(*image_info.size)
      end
      # make sure we're at the beginning of the file
      # (FastImage and Nokogiri move the pointer)
      file.rewind
    rescue FastImage::ImageFetchFailure
      upload.errors.add(:base, I18n.t("upload.images.fetch_failure"))
    rescue FastImage::UnknownImageType
      upload.errors.add(:base, I18n.t("upload.images.unknown_image_type"))
    rescue FastImage::SizeNotFound
      upload.errors.add(:base, I18n.t("upload.images.size_not_found"))
    end

    upload
  end

  def self.get_from_url(url)
    return if url.blank?
    # we store relative urls, so we need to remove any host/cdn
    url = url.sub(/^#{Discourse.asset_host}/i, "") if Discourse.asset_host.present?
    # when using s3, we need to replace with the absolute base url
    url = url.sub(/^#{SiteSetting.s3_cdn_url}/i, Discourse.store.absolute_base_url) if SiteSetting.s3_cdn_url.present?
    Upload.find_by(url: url) if Discourse.store.has_been_uploaded?(url)
  end

  def self.fix_image_orientation(path)
    `convert #{path} -auto-orient #{path}`
  end

end

# == Schema Information
#
# Table name: uploads
#
#  id                :integer          not null, primary key
#  user_id           :integer          not null
#  original_filename :string(255)      not null
#  filesize          :integer          not null
#  width             :integer
#  height            :integer
#  url               :string(255)      not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  sha1              :string(40)
#  origin            :string(1000)
#  retain_hours      :integer
#
# Indexes
#
#  index_uploads_on_id_and_url  (id,url)
#  index_uploads_on_sha1        (sha1) UNIQUE
#  index_uploads_on_url         (url)
#  index_uploads_on_user_id     (user_id)
#
