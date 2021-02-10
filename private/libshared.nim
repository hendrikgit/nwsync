import logging, os, sequtils, strutils, critbits, algorithm
import neverwinter/resman, neverwinter/resdir, neverwinter/key,
  neverwinter/erf, neverwinter/gff, neverwinter/resfile

proc abort*(args: varargs[string, `$`]) = fatal(args); quit(1)

proc getFilesInStorage*(rootDirectory: string): CritBitTree[string] =
  # hash => full path to file

  # nb: we don't know how to handle file links yet.
  for entry in walkDirRec(rootDirectory / "data", yieldFilter = {pcFile}, followFilter = {pcDir, pcLinkToDir}):
    let ha = extractFilename(entry)
    result[ha] = entry

proc newResMan*(entries: seq[string], includeModContents: bool): ResMan =
  ## Reindexes the given module.
  let resman = newResMan(0)

  for entry in entries:
    let pa = splitFile(entry)
    let isDir = dirExists(entry)
    let isFile = fileExists(entry)

    if isDir:
      info "Adding directory: ", entry
      resman.add newResDir(entry)

    elif isFile:
      # let pa = splitPath(entry)
      let fs = openFileStream(entry, fmRead)
      let hdr = fs.peekStr(3)

      if hdr == "KEY":
        info "Adding key: ", entry
        resman.add readKeyTable(fs, entry) do (fn: string) -> Stream:
          info "  Adding bif: ", fn, " at ", pa.dir
          result = openFileStream(pa.dir / ".." / fn, fmRead)
          doAssert(not isNil result)

      elif hdr == "ERF" or hdr == "HAK":
        info "Adding hak: ", entry
        resman.add readErf(fs, entry)

      elif hdr == "MOD":
        info "Parsing .mod to extract hak and tlk info: ", entry
        let erf = readErf(fs, entry)

        if includeModContents:
          info "Including module contents"
          resman.add erf

        let ifo = erf.demand(newResolvedResRef "module.ifo").readAll(useCache=false)
        let ifogff = readGffRoot(newStringStream(ifo), false)

        if ifogff.hasField("Mod_HakList", GffList):
          let haklist = ifogff["Mod_HakList", GffList].mapIt(it["Mod_Hak", GffCExoString])
          info "Found ", haklist.len, " haks inside .mod"

          # Now we resolve all the mod and hak names from the search path
          for hak in reversed(haklist):
            # Lookup path for now is hardcoded to be the basic NWN structure.
            # We first resolve by hk, then by hak.
            let paths = [
              pa.dir / ".." / "hk" / hak & ".hak",
              pa.dir / ".." / "hak" / hak & ".hak"
            ].filterIt(it.fileExists)

            if paths.len == 0:
              raise newException(ValueError, "Cannot resolve hak from mod (not found): " & hak)
            let erfio = openFileStream(paths[0], fmRead)
            resman.add readErf(erfio, paths[0])
            info "Adding hak from mod: ", paths[0]

        else:
          info "Module does not contain any HAKs"

        let tlk =
          if ifogff.hasField("Mod_CustomTlk", GffCExoString): ifogff["Mod_CustomTlk", GffCExoString]
          else: ""

        if tlk != "":
          let tlkloc = pa.dir / ".." / "tlk" / tlk & ".tlk"
          info "Adding tlk from mod: ", tlkloc
          resman.add newResFile(tlkloc)
        else:
          info "Module does not contain a TLK"

      else:
        info "Adding single file: ", entry
        resman.add newResFile(entry)

    else:
      abort "Not found or inaccessible: ", entry

  result = resman
