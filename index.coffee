crcUtils = require '@balena/node-crc-utils'
CombinedStream = require 'combined-stream'
{ DeflateCRC32Stream } = require 'crc32-stream'

# Zip constants, explained how they are used on each function.
ZIP_VERSION = Buffer.from([ 0x0a, 0x00 ])
ZIP_FLAGS = Buffer.from([ 0x00, 0x00 ])
ZIP_ENTRY_SIGNATURE = Buffer.from([ 0x50, 0x4b, 0x03, 0x04 ])
ZIP_ENTRY_EXTRAFIELD_LEN = Buffer.from([ 0x00, 0x00 ])
ZIP_COMPRESSION_DEFLATE = Buffer.from([ 0x08, 0x00 ])
ZIP_CD_SIGNATURE = Buffer.from([ 0x50, 0x4b, 0x01, 0x02 ])
ZIP_CD_VERSION = Buffer.from([ 0x1e, 0x03 ])
ZIP_CD_FILE_COMM_LEN = Buffer.from([ 0x00, 0x00 ])
ZIP_CD_DISK_START = Buffer.from([ 0x00, 0x00 ])
ZIP_CD_INTERNAL_ATT = Buffer.from([ 0x01, 0x00 ])
ZIP_CD_EXTERNAL_ATT = Buffer.from([ 0x00, 0x00, 0xa4, 0x81 ])
ZIP_ECD_SIGNATURE = Buffer.from([ 0x50, 0x4b, 0x05, 0x06 ])
ZIP_ECD_DISK_NUM = Buffer.from([ 0x00, 0x00 ])
ZIP_ECD_COMM_LEN = Buffer.from([ 0x00, 0x00 ])
ZIP_ECD_SIZE = 22
ZIP_VERSION_ZIP64 = Buffer.from([ 0x2d, 0x00 ])
ZIP64_EXTRA_TAG = Buffer.from([ 0x01, 0x00 ])
ZIP64_ECD_SIGNATURE = Buffer.from([ 0x50, 0x4b, 0x06, 0x06 ])
ZIP64_ECD_LOCATOR_SIGNATURE = Buffer.from([ 0x50, 0x4b, 0x06, 0x07 ])
ZIP64_OVERHEAD = 76  # Zip64 EOCD (56) + Zip64 EOCD Locator (20)
ZIP64_MAGIC_NUMBER = 0xFFFFFFFF # 2^32-1, the maximum value for compressed and uncompressed sizes in non-Zip64 format
ZIP64_MAGIC_BUFFER = Buffer.from([ 0xff, 0xff, 0xff, 0xff ])

# DEFLATE ending block
DEFLATE_END = Buffer.from([ 0x03, 0x00 ])

# Use the logic briefly described here by the author of zlib library:
# http://stackoverflow.com/questions/14744692/concatenate-multiple-zlib-compressed-data-streams-into-a-single-stream-efficient#comment51865187_14744792
# to generate deflate streams that can be concatenated into a gzip stream
class DeflatePartStream extends DeflateCRC32Stream
	constructor: ->
		super(arguments...)
		@buf = Buffer.alloc(0)
	push: (chunk) ->
		if chunk isnt null
			# got another chunk, previous chunk is safe to send
			super(@buf)
			@buf = chunk
		else
			# got null signalling end of stream
			# inspect last chunk for 2-byte DEFLATE_END marker and remove it
			if @buf.length >= 2 and @buf[-2..].equals(DEFLATE_END)
				@buf = @buf[...-2]
			super(@buf)
			super(null)
	end: ->
		@flush =>
			super()
	metadata: ->
		crc: @digest().readUInt32BE(0)
		len: @size()
		zLen: @size(true)

exports.createDeflatePart = ->
	return new DeflatePartStream()

# Calculate length of file entry header
# length of static information + filename length + extrafield length (0 or 20 for zip64)
fileHeaderLength = (filename, zip64) -> 30 + filename.length + (if zip64 then 20 else 0)

# Calculate length of central directory record
# length of static information + filename length + central directory extrafield length (0 or 28 for zip64)
centralDirectoryLength = (filename, zip64) -> 0x2e + filename.length + (if zip64 then 28 else 0)

# Return unsigned int as a buffer in little endian.
# The size of the buffer needs to be passed as 2nd argument.
iob = (number, size) ->
	b = Buffer.alloc(size)
	b.fill(0).writeUIntLE(number, 0, size)
	return b

# Return unsigned 64-bit int as a buffer in little endian.
iob8 = (number) ->
	b = Buffer.alloc(8)
	b.writeBigUInt64LE(BigInt(number))
	return b

# Create zip64 extra field for local file header (original + compressed size)
createZip64LocalExtra = (uncompressed_size, compressed_size) ->
	data = Buffer.concat([ iob8(uncompressed_size), iob8(compressed_size) ])
	Buffer.concat([ ZIP64_EXTRA_TAG, iob(data.length, 2), data ])

# Create file entry header
# Structure:
#               2       4       6       8       10      12      14      16
# 0000  | SIGNATURE     | VERS  | FLAGS | COMPM | MTIME | MDATE | CRC..
# 0010    ..CRC | COMP_LEN      | RAW_LEN       | LNAME | LEXTR | FI..
# 0020                       ...FILENAME (variable length)
# 0030			     EXTRAFIELD (variable length)
#
# Where:
# 	SIGNATURE: Zip file entry signature (const)
# 	VERSION: Zip version required
# 	FLAGS: For us a constant 0000
# 	COMPM: Compression method or 0 for no compression
# 	MTIME / MDATE: Modification date
# 	CRC: 32-bit crc checksum
# 	COMP_LEN / RAW_LEN: Compressed and uncompressed length of contents
# 	LNAME: Filename length
# 	LEXTR: Length of extrafields attribute (last attribute)
# 	FILENAME: Filename, ascii
# 	EXTRAFIELD: Description of further custom properties (we use a constant)
createFileHeader = ({ filename, compressed_size, uncompressed_size, crc, mtime, mdate, zip64 }) ->
	localExtra = if zip64 then createZip64LocalExtra(uncompressed_size, compressed_size) else Buffer.alloc(0)
	Buffer.concat([
		ZIP_ENTRY_SIGNATURE
		if zip64 then ZIP_VERSION_ZIP64 else ZIP_VERSION
		ZIP_FLAGS
		ZIP_COMPRESSION_DEFLATE
		mtime
		mdate
		crc
		if zip64 then ZIP64_MAGIC_BUFFER else iob(compressed_size, 4)
		if zip64 then ZIP64_MAGIC_BUFFER else iob(uncompressed_size, 4)
		iob(filename.length, 2)
		if zip64 then iob(localExtra.length, 2) else ZIP_ENTRY_EXTRAFIELD_LEN
		Buffer.from(filename)
		localExtra
	])

# Create zip64 extra field for central directory record (original + compressed size + header offset)
createZip64CDExtra = (uncompressed_size, compressed_size, headerOffset) ->
	data = Buffer.concat([ iob8(uncompressed_size), iob8(compressed_size), iob8(headerOffset) ])
	Buffer.concat([ ZIP64_EXTRA_TAG, iob(data.length, 2), data ])

# Create central directory record, where each of the files in zip are listed (again)
# Structure for each file entry:
#               2       4       6       8       10      12      14      16
# 0000  | CD SIGNATURE  | CDV   | VERS  | FLAGS | COMPM | MTIME | MDATE |
# 0010  | CRC           | COMP_LEN      | RAW_LEN       | LNAME | LEXTR |
# 0020  | LCOMM | #DISK | I ATT | EXTERNAL ATT  | FILE H OFFSET | FI...
# 0020                       ...FILENAME (variable length)
# 0030			     EXTRAFIELD (variable length)
# 0040			     COMMENT (variable length, optional)
#
# Where:
# 	CD SIGNATURE: Zip central directory signature (const)
# 	CDV: Version of central directory
# 	VERS: Zip version required
#	FLAGS: Extra flags, here a constant 0000
#	COMPM, MTIME, MDATE, CRC, COMP_LEN, RAW_LEN, LNAME: Same as file header
#	LCOMM: Length of file comment (always 0 here, no support for comments)
#	#DISK: Disk number the files start (for multi-disk zip files, always 0 here)
#	I ATT: File attributes used internally by the compressors and decompressors (const here)
#	EXTERNAL ATT: Attributes useful for external applications (const here)
#	FILE H OFFSET: Offset of file header from the start of zip file
#	FILENAME: Filename, ascii
#	EXTRAFIELD: Description of further custom properties (const here)
#	COMMENT: File comment (none here, no support for comments)
createCDRecord = ({ filename, compressed_size, uncompressed_size, crc, mtime, mdate, zip64 }, fileHeaderOffset) ->
	cdExtra = if zip64 then createZip64CDExtra(uncompressed_size, compressed_size, fileHeaderOffset) else Buffer.alloc(0)
	Buffer.concat([
		ZIP_CD_SIGNATURE
		ZIP_CD_VERSION
		if zip64 then ZIP_VERSION_ZIP64 else ZIP_VERSION
		ZIP_FLAGS
		ZIP_COMPRESSION_DEFLATE
		mtime
		mdate
		crc
		if zip64 then ZIP64_MAGIC_BUFFER else iob(compressed_size, 4)
		if zip64 then ZIP64_MAGIC_BUFFER else iob(uncompressed_size, 4)
		iob(filename.length, 2)
		if zip64 then iob(cdExtra.length, 2) else ZIP_ENTRY_EXTRAFIELD_LEN
		ZIP_CD_FILE_COMM_LEN
		ZIP_CD_DISK_START
		ZIP_CD_INTERNAL_ATT
		ZIP_CD_EXTERNAL_ATT
		if zip64 then ZIP64_MAGIC_BUFFER else iob(fileHeaderOffset, 4)
		Buffer.from(filename)
		cdExtra
	])

# Create End of Central Directory Record
# Structure:
#               2       4       6       8       10      12      14      16
# 0010  | ECD SIGNATURE | NDISK | #DISK | CDS   | FILES | CDSZ  | CDOFF |
# 0020  | ECOMM |            COMMENT (variable length, optional)
#
# Where:
# 	ECD SIGNATURE: Signature of end of central directory record
# 	NDISK: Number of disks the archive spans
# 	#DISK: Disk central directory exists
# 	CDS: Number of central directory entries
# 	FILES: Total number of files in the archive
# 	CDSZ: Size of central directory
# 	CDOFF: Offset of central directory from disk it exists
createEndOfCDRecord = (entries) ->
	cd_offset = entries.reduce(((sum, x) -> sum + fileHeaderLength(x.filename, x.zip64) + x.compressed_size), 0)
	cd_size = entries.reduce(((sum, x) -> sum + centralDirectoryLength(x.filename, x.zip64)), 0)
	if entries.some((x) -> x.zip64)
		zip64EOCD = Buffer.concat([
			ZIP64_ECD_SIGNATURE
			iob8(44)
			ZIP_CD_VERSION
			ZIP_VERSION_ZIP64
			iob(0, 4)
			iob(0, 4)
			iob8(entries.length)
			iob8(entries.length)
			iob8(cd_size)
			iob8(cd_offset)
		])
		zip64Locator = Buffer.concat([
			ZIP64_ECD_LOCATOR_SIGNATURE
			iob(0, 4)
			iob8(cd_offset + cd_size)
			iob(1, 4)
		])
		eocd = Buffer.concat([
			ZIP_ECD_SIGNATURE
			ZIP_ECD_DISK_NUM
			ZIP_CD_DISK_START
			ZIP64_MAGIC_BUFFER
			ZIP64_MAGIC_BUFFER
			ZIP64_MAGIC_BUFFER
			ZIP_ECD_COMM_LEN
		])
		Buffer.concat([ zip64EOCD, zip64Locator, eocd ])
	else
		Buffer.concat([
			ZIP_ECD_SIGNATURE
			ZIP_ECD_DISK_NUM
			ZIP_CD_DISK_START
			iob(entries.length, 2)
			iob(entries.length, 2)
			iob(cd_size, 4)
			iob(cd_offset, 4)
			ZIP_ECD_COMM_LEN
		])

dosFormatTime = (d) ->
	buf = Buffer.alloc(2)
	buf.writeUIntLE((d.getSeconds() / 2) + (d.getMinutes() << 5) + (d.getHours() << 11), 0, 2)
	return buf

dosFormatDate = (d) ->
	buf = Buffer.alloc(2)
	buf.writeUIntLE(d.getDate() + ((d.getMonth() + 1) << 5) + ((d.getFullYear() - 1980) << 9), 0, 2)
	return buf

getCombinedCrc = (parts) ->
	if parts.length == 1
		# crc32 is stored as a number, has to be transformed to a Buffer
		buf = Buffer.alloc(4)
		buf.writeUInt32LE(parts[0].crc, 0, 4)
		return buf
	else
		CRC32_PERIOD_NUMBER = 0xFFFFFFFF # 2^32-1
		normalizedParts = parts.map (p) ->
			# crc32_combine(crc1, crc2, n) receives len as a 32-bit integer, so any len >= 2^32 must be reduced here.
			if p.len <= CRC32_PERIOD_NUMBER
				return p
			return { crc: p.crc, len: p.len % CRC32_PERIOD_NUMBER }
		crcUtils.crc32_combine_multi(normalizedParts).combinedCrc32


exports.totalLength = totalLength = (entries) ->
	zip64Overhead = if entries.some((e) -> e.zip64) then ZIP64_OVERHEAD else 0
	ZIP_ECD_SIZE + zip64Overhead + entries.reduce ((sum, x) -> sum + x.zLen), 0

exports.createEntry = createEntry = (filename, parts, mdate, options) ->
	mdate ?= new Date()
	options ?= {}
	compressed_size = parts.reduce ((sum, x) -> sum + x.zLen), DEFLATE_END.length
	uncompressed_size = parts.reduce ((sum, x) -> sum + x.len), 0
	zip64 = compressed_size > ZIP64_MAGIC_NUMBER or uncompressed_size > ZIP64_MAGIC_NUMBER or options.forceZip64 == true
	contentLength = fileHeaderLength(filename, zip64) + compressed_size
	entry =
		filename: filename
		compressed_size: compressed_size
		uncompressed_size: uncompressed_size
		crc: getCombinedCrc(parts)
		mtime: dosFormatTime(mdate)
		mdate: dosFormatDate(mdate)
		contentLength: contentLength
		zLen: contentLength + centralDirectoryLength(filename, zip64)
		zip64: zip64
		stream: CombinedStream.create()
	entry.stream.append(createFileHeader(entry))
	entry.stream.append(stream) for { stream } in parts
	entry.stream.append(DEFLATE_END)
	return entry

exports.create = create = (entries) ->
	out = CombinedStream.create()
	out.append(entry.stream) for entry in entries
	offset = 0
	for entry in entries
		out.append(createCDRecord(entry, offset))
		offset += entry.contentLength
	out.append(createEndOfCDRecord(entries))
	out.zLen = totalLength(entries)
	return out

# DEPRECATED
# Single-entry zip archive backwards-compatibility
exports.createZip = (filename, parts, mdate) ->
	entry = createEntry(filename, parts, mdate)
	create([ entry ])
