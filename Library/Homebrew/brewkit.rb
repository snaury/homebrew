#  Copyright 2009 Max Howell and other contributors.
#
#  Redistribution and use in source and binary forms, with or without
#  modification, are permitted provided that the following conditions
#  are met:
#
#  1. Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimer.
#  2. Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in the
#     documentation and/or other materials provided with the distribution.
#
#  THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
#  IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
#  OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
#  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
#  INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
#  NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
#  DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
#  THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
#  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
#  THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
require 'fileutils'
require 'formula'
require 'download_strategy'
require 'hardware'

# TODO
# 1. Indeed, there should be an option to build 32 or 64 bit binaries
# 2. Homebrew will not support building 32 and 64 bit lipo'd binaries, I
#    want to mind, but the simple fact is it is difficult to force most of the
#    build systems we support to do it.


`/usr/bin/sw_vers -productVersion` =~ /(10\.\d+)(\.\d+)?/
MACOS_VERSION=$1.to_f

ENV['MACOSX_DEPLOYMENT_TARGET']=MACOS_VERSION.to_s
ENV['LDFLAGS']='' # to be consistent, we ignore the existing environment

# this is first, so when you see it in output, you notice it
cflags='-O3'

if MACOS_VERSION >= 10.6
  if Hardware.is_64bit?
    # 64 bits baby!
    cflags<<" -m64"
    ENV['LDFLAGS']="-arch x86_64"
  end
end

case Hardware.cpu_type
when :ppc   then abort "Sorry, Homebrew does not support PowerPC architectures"
when :dunno then abort "Sorry, Homebrew cannot determine what kind of Mac this is!"
end

# -w: keep signal to noise high
# -fomit-frame-pointer: we are not debugging this software, we are using it
ENV['CFLAGS']="#{cflags} -w -pipe -fomit-frame-pointer -mmacosx-version-min=#{MACOS_VERSION}"
ENV['CXXFLAGS']=ENV['CFLAGS']

# lets use gcc 4.2, Xcode does after all
if MACOS_VERSION==10.5
  ENV['CC']='gcc-4.2'
  ENV['CXX']='g++-4.2'
end
# compile faster
ENV['MAKEFLAGS']="-j#{Hardware.processor_count}"


# /usr/local is always in the build system path
unless HOMEBREW_PREFIX.to_s == '/usr/local'
  ENV['CPPFLAGS']="-I#{HOMEBREW_PREFIX}/include"
  ENV['LDFLAGS']="-L#{HOMEBREW_PREFIX}/lib"
end


# you can use these functions for packages that have build issues
module HomebrewEnvExtension
  def deparallelize
    remove 'MAKEFLAGS', /-j\d+/
  end
  alias_method :j1, :deparallelize
  def gcc_4_0_1
    case MACOS_VERSION
      when 10.5
        self['CC']=nil
        self['CXX']=nil
      when 10.6..11.0
        self['CC']='gcc-4.0'
        self['CXX']='g++-4.0'
    end
    
    # argh, we have to figure out the compile options ourselves and get
    # rid of -march=native, so we optimise all the way to eleven, references:
    # http://en.gentoo-wiki.com/wiki/Safe_Cflags/Intel
    # http://forums.mozillazine.org/viewtopic.php?f=12&t=577299
    # http://gcc.gnu.org/onlinedocs/gcc-4.2.1/gcc/i386-and-x86_002d64-Options.html
    remove_from_cflags '-march=native'
    append_to_cflags Hardware.gcc_march
    append_to_cflags Hardware.gcc_msse
    append_to_cflags Hardware.gcc_mmx
  end
  def osx_10_4
    self['MACOSX_DEPLOYMENT_TARGET']=nil
    remove_from_cflags(/ ?-mmacosx-version-min=10\.\d/)
  end
  def generic_i386
     %w[-mfpmath=sse -msse3 -mmmx -march=\w+].each {|s| remove_from_cflags s}
  end
  def libxml2
    append_to_cflags ' -I/usr/include/libxml2'
  end
  # TODO rename or alias to x11
  def libpng
    # CPPFLAGS are the C-PreProcessor flags, *not* C++!
    append 'CPPFLAGS', '-I/usr/X11R6/include'
    append 'LDFLAGS', '-L/usr/X11R6/lib'
  end
  # we've seen some packages fail to build when warnings are disabled!
  def enable_warnings
    remove_from_cflags '-w'
  end

private
  def append key, value
    ref=self[key]
    if ref.nil? or ref.empty?
      self[key]=value
    else
      self[key]=ref+' '+value
    end
  end
  def append_to_cflags f
    append 'CFLAGS', f
    append 'CXXFLAGS', f
  end
  def remove key, value
    return if self[key].nil?
    self[key]=self[key].sub value, '' # can't use sub! on ENV
    self[key]=nil if self[key].empty? # keep things clean
  end
  def remove_from_cflags f
    remove 'CFLAGS', f
    remove 'CXXFLAGS', f
  end
end

ENV.extend HomebrewEnvExtension


# remove MacPorts and Fink from the PATH, this prevents issues like:
# http://github.com/mxcl/homebrew/issues/#issue/13
paths=ENV['PATH'].split(':').reject do |p|
  p.squeeze! '/'
  p =~ %r[^/opt/local] or p =~ %r[^/sw]
end
ENV['PATH']=paths*':'


def inreplace(path, before, after)
  before=Regexp.escape before.to_s
  before.gsub! "/", "\\/" # I guess not escaped as delimiter varies
  after=after.to_s
  after.gsub! "\\", "\\\\"
  after.gsub! "/", "\\/"

  # FIXME use proper Ruby for teh exceptions!
  safe_system "perl", "-pi", "-e", "s/#{before}/#{after}/g", path
end
