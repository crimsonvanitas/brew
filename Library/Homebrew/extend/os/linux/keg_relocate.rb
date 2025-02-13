# typed: true
# frozen_string_literal: true

require "compilers"

class Keg
  def relocate_dynamic_linkage(relocation)
    # Patching the dynamic linker of glibc breaks it.
    return if name.match? Version.formula_optionally_versioned_regex(:glibc)

    # Patching patchelf fails with "Text file busy" or SIGBUS.
    return if name == "patchelf"

    old_prefix, new_prefix = relocation.replacement_pair_for(:prefix)

    elf_files.each do |file|
      file.ensure_writable do
        change_rpath(file, old_prefix, new_prefix)
      end
    end
  end

  def change_rpath(file, old_prefix, new_prefix)
    return if !file.elf? || !file.dynamic_elf?

    updated = {}
    old_rpath = file.rpath
    new_rpath = if old_rpath
      rpath = old_rpath.split(":")
                       .map { |x| x.sub(old_prefix, new_prefix) }
                       .select { |x| x.start_with?(new_prefix, "$ORIGIN") }

      lib_path = "#{new_prefix}/lib"
      rpath << lib_path unless rpath.include? lib_path

      # Add GCC's lib directory (as of GCC 12+) to RPATH when there is existing linkage.
      # This fixes linkage for newly-poured bottles.
      if !name.match?(Version.formula_optionally_versioned_regex(:gcc)) &&
         rpath.any? { |rp| rp.match?(%r{lib/gcc/\d+$}) }
        # TODO: Replace with
        #   rpath.map! { |path| path = path.sub(%r{lib/gcc/\d+$}, "lib/gcc/current") }
        # when
        #   1. Homebrew/homebrew-core#106755 is merged
        #   2. No formula has a runtime dependency on a versioned GCC (see `envoy.rb`)
        rpath.prepend HOMEBREW_PREFIX/"opt/gcc/lib/gcc/current"
      end

      rpath.join(":")
    end
    updated[:rpath] = new_rpath if old_rpath != new_rpath

    old_interpreter = file.interpreter
    new_interpreter = if old_interpreter.nil?
      nil
    elsif File.readable? "#{new_prefix}/lib/ld.so"
      "#{new_prefix}/lib/ld.so"
    else
      old_interpreter.sub old_prefix, new_prefix
    end
    updated[:interpreter] = new_interpreter if old_interpreter != new_interpreter

    file.patch!(interpreter: updated[:interpreter], rpath: updated[:rpath])
  end

  def detect_cxx_stdlibs(options = {})
    skip_executables = options.fetch(:skip_executables, false)
    results = Set.new
    elf_files.each do |file|
      next unless file.dynamic_elf?
      next if file.binary_executable? && skip_executables

      dylibs = file.dynamically_linked_libraries
      results << :libcxx if dylibs.any? { |s| s.include? "libc++.so" }
      results << :libstdcxx if dylibs.any? { |s| s.include? "libstdc++.so" }
    end
    results.to_a
  end

  def elf_files
    hardlinks = Set.new
    elf_files = []
    path.find do |pn|
      next if pn.symlink? || pn.directory?
      next if !pn.dylib? && !pn.binary_executable?

      # If we've already processed a file, ignore its hardlinks (which have the
      # same dev ID and inode). This prevents relocations from being performed
      # on a binary more than once.
      next unless hardlinks.add? [pn.stat.dev, pn.stat.ino]

      elf_files << pn
    end
    elf_files
  end

  def self.bottle_dependencies
    @bottle_dependencies ||= begin
      formulae = []
      gcc = Formulary.factory(CompilerSelector.preferred_gcc)
      if !Homebrew::EnvConfig.simulate_macos_on_linux? &&
         DevelopmentTools.non_apple_gcc_version("gcc") < gcc.version.to_i
        formulae << gcc
      end
      formulae
    end
  end
end
