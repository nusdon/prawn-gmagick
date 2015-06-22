require "prawn"
require_relative "../image"

class Gmagick < Prawn::Images::Image
  attr_reader :palette, :img_data, :transparency
  attr_reader :width, :height, :bits
  attr_reader :color_type, :compression_method, :filter_method
  attr_reader :interlace_method, :alpha_channel
  attr_accessor :scaled_width, :scaled_height
  attr_accessor :gwidth, :gheight, :gbits
  attr_accessor :gimage

  def self.can_render?(image_blob)
    GMagick::Image.format(image_blob) ? true : false
  end

  # Process a new PNG image
  #
  # <tt>data</tt>:: A binary string of PNG data
  #
  def initialize(data)
    data = StringIO.new(data.dup)

    data.read(8)  # Skip the default header

    @palette  = ""
    @img_data = ""
    @transparency = {}

    loop do
      chunk_size  = data.read(4).unpack("N")[0]
      section     = data.read(4)
      case section
      when 'IHDR'
        # we can grab other interesting values from here (like width,
        # height, etc)
        values = data.read(chunk_size).unpack("NNCCCCC")

        @width              = values[0]
        @height             = values[1]
        @bits               = values[2]
        @color_type         = values[3]
        @compression_method = values[4]
        @filter_method      = values[5]
        @interlace_method   = values[6]
      when 'PLTE'
        @palette << data.read(chunk_size)
      when 'IDAT'
        @img_data << data.read(chunk_size)
      when 'tRNS'
        # This chunk can only occur once and it must occur after the
        # PLTE chunk and before the IDAT chunk
        @transparency = {}
        case @color_type
        when 3
          # fail Errors::UnsupportedImageType,
          #      "Pallete-based transparency in PNG is not currently supported.\n" \
          #      "See https://github.com/prawnpdf/prawn/issues/783"
          self.gimage = GMagick::Image.new data
          self.gbits = gimage.depth
          self.gwidth = gimage.width
          self.gheight = gimage.height

        when 0
          # Greyscale. Corresponding to entries in the PLTE chunk.
          # Grey is two bytes, range 0 .. (2 ^ bit-depth) - 1
          grayval = data.read(chunk_size).unpack("n").first
          @transparency[:grayscale] = grayval
        when 2
          # True colour with proper alpha channel.
          @transparency[:rgb] = data.read(chunk_size).unpack("nnn")
        end
      when 'IEND'
        # we've got everything we need, exit the loop
        break
      else
        # unknown (or un-important) section, skip over it
        data.seek(data.pos.to_i + chunk_size.to_i)
      end

      data.read(4)  # Skip the CRC
    end

    @img_data = Zlib::Inflate.inflate(@img_data)
  rescue StandardError => e
    puts "Nothing"
    @color_type = 2
    self.gimage = GMagick::Image.new data
    self.gbits = gimage.depth
    self.gwidth = gimage.width
    self.gheight = gimage.height
  end

  # number of color components to each pixel
  #
  def colors
    case self.color_type
    when 0, 3, 4
      return 1
    when 2, 6
      return 3
    end
  end

  # split the alpha channel data from the raw image data in images
  # where it's required.
  #
  def split_alpha_channel!
    split_image_data if alpha_channel?
  end

  def alpha_channel?
    @color_type == 4 || @color_type == 6
  end

  # Build a PDF object representing this image in +document+, and return
  # a Reference to it.
  #
  def build_pdf_object(document)

    # some PNG types store the colour and alpha channel data together,
    # which the PDF spec doesn't like, so split it out.
    split_alpha_channel!
    case colors
    when 1
      color = :DeviceGray
      obj = render_image(document, color)
    when 3
      color = :DeviceRGB
      obj = render_image(document, color)
    else
      obj = document.ref!(
        Type: :XObject,
        Subtype: :Image,
        ColorSpace: gimage.colorspace,
        Height: gheight,
        Width: gwidth,
        BitsPerComponent: gbits
      )

      obj << gimage.unpack
      obj.stream.filters << { FlateDecode: nil }

      alpha_mask = self.gimage.alpha_unpack
      if alpha_mask.unpack("C*").uniq.length > 1
        smask_obj = document.ref!(
                :Type             => :XObject,
                :Subtype          => :Image,
                :Height           => gheight,
                :Width            => gwidth,
                :BitsPerComponent => gbits,
                :ColorSpace       => :DeviceRGB,
                :Decode           => [0, 1]
        )
        smask_obj.stream << alpha_mask
        obj.data[:SMask] = smask_obj
      end
    end
    obj
  end

  # Returns the minimum PDF version required to support this image.
  def min_pdf_version
    if bits > 8
      # 16-bit color only supported in 1.5+ (ISO 32000-1:2008 8.9.5.1)
      1.5
    elsif alpha_channel?
      # Need transparency for SMask
      1.4
    else
      1.0
    end
  end

  private

  def split_image_data
    alpha_bytes = bits / 8
    color_bytes = colors * bits / 8

    scanline_length  = (color_bytes + alpha_bytes) * self.width + 1
    scanlines = @img_data.bytesize / scanline_length
    pixels = self.width * self.height

    data = StringIO.new(@img_data)
    data.binmode

    color_data = [0x00].pack('C') * (pixels * color_bytes + scanlines)
    color = StringIO.new(color_data)
    color.binmode

    @alpha_channel = [0x00].pack('C') * (pixels * alpha_bytes + scanlines)
    alpha = StringIO.new(@alpha_channel)
    alpha.binmode

    scanlines.times do |line|
      data.seek(line * scanline_length)

      filter = data.getbyte

      color.putc filter
      alpha.putc filter

      self.width.times do
        color.write data.read(color_bytes)
        alpha.write data.read(alpha_bytes)
      end
    end

    @img_data = color_data
  end

  def render_image(document, color)
    # build the image dict
    obj = document.ref!(
      :Type             => :XObject,
      :Subtype          => :Image,
      :Height           => height,
      :Width            => width,
      :BitsPerComponent => bits
    )

    # append the actual image data to the object as a stream
    obj << img_data

    obj.stream.filters << {
      :FlateDecode => {
        :Predictor => 15,
        :Colors    => colors,
        :BitsPerComponent => bits,
        :Columns   => width
      }
    }

    # sort out the colours of the image
    if palette.empty?
      obj.data[:ColorSpace] = color
    else
      # embed the colour palette in the PDF as a object stream
      palette_obj = document.ref!({})
      palette_obj << palette

      # build the color space array for the image
      obj.data[:ColorSpace] = [:Indexed,
                               :DeviceRGB,
                               (palette.size / 3) - 1,
                               palette_obj]
    end

    # *************************************
    # add transparency data if necessary
    # *************************************

    # For PNG color types 0, 2 and 3, the transparency data is stored in
    # a dedicated PNG chunk, and is exposed via the transparency attribute
    # of the PNG class.
    if transparency[:grayscale]
      # Use Color Key Masking (spec section 4.8.5)
      # - An array with N elements, where N is two times the number of color
      #   components.
      val = transparency[:grayscale]
      obj.data[:Mask] = [val, val]
    elsif transparency[:rgb]
      # Use Color Key Masking (spec section 4.8.5)
      # - An array with N elements, where N is two times the number of color
      #   components.
      rgb = transparency[:rgb]
      obj.data[:Mask] = rgb.collect { |x| [x, x] }.flatten
    end

    # For PNG color types 4 and 6, the transparency data is stored as a alpha
    # channel mixed in with the main image data. The PNG class seperates
    # it out for us and makes it available via the alpha_channel attribute
    if alpha_channel?
      smask_obj = document.ref!(
        :Type             => :XObject,
        :Subtype          => :Image,
        :Height           => height,
        :Width            => width,
        :BitsPerComponent => bits,
        :ColorSpace       => :DeviceGray,
        :Decode           => [0, 1]
      )
      smask_obj.stream << alpha_channel

      smask_obj.stream.filters << {
        :FlateDecode => {
          :Predictor => 15,
          :Colors    => 1,
          :BitsPerComponent => bits,
          :Columns   => width
        }
      }
      obj.data[:SMask] = smask_obj
    end
    return obj
  end
end

Prawn.image_handler.unregister Prawn::Images::PNG
Prawn.image_handler.register Gmagick