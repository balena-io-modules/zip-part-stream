crcUtils = require 'resin-crc-utils'
CombinedStream = require 'combined-stream2'
{ DeflateCRC32Stream } = require 'crc32-stream'

# Zip constants, explained how they are used on each function.
ZIP_VERSION = '0a00'
ZIP_FLAGS = '0000'
ZIP_ENTRY_SIGNATURE = '504b0304'
ZIP_ENTRY_EXTRAFIELD = ''
ZIP_ENTRY_EXTRAFIELD_LEN = 0
ZIP_COMPRESSION_DEFLATE = '0000'
ZIP_COMPRESSION_DEFLATE = '0800'
ZIP_CD_SIGNATURE = '504b0102'
ZIP_CD_VERSION = '1e03'
ZIP_CD_FILE_COMM_LEN = 0
ZIP_CD_DISK_START = 0
ZIP_CD_INTERNAL_ATT = '0100'
ZIP_CD_EXTERNAL_ATT = '0000a481'
ZIP_CD_EXTRAFIELD = ''
ZIP_CD_EXTRAFIELD_LEN = 0
ZIP_ECD_SIGNATURE = '504b0506'
ZIP_ECD_DISK_NUM = 0
ZIP_ECD_COMM_LEN = 0
ZIP_ECD_SIZE = 22

# DEFLATE ending block
DEFLATE_END = new Buffer([ 0x03, 0x00 ])

# Use the logic briefly described here by the author of zlib library:
# http://stackoverflow.com/questions/14744692/concatenate-multiple-zlib-compressed-data-streams-into-a-single-stream-efficient#comment51865187_14744792
# to generate deflate streams that can be concatenated into a gzip stream
class DeflatePartStream extends DeflateCRC32Stream
	constructor: ->
		@buf = new Buffer(0)
		super
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
		crc: @digest()
		len: @size()
		zLen: @size(true)

exports.createDeflatePart = ->
	return new DeflatePartStream()

# Calculate length of file entry header
# length of static information + filename length + extrafield length
fileHeaderLength = (filename) -> 30 + filename.length + ZIP_ENTRY_EXTRAFIELD_LEN

# Calculate length of central directory (assumes only one file)
# length of static information + filename length + central directory extrafield length
centralDirectoryLength = (filename) -> 0x2e + filename.length + ZIP_CD_EXTRAFIELD_LEN

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
createFileHeader = ({ filename, compressed_size, uncompressed_size, crc, mtime, mdate }) ->
	fileHeader = new Buffer(fileHeaderLength(filename))
	fileHeader.write(ZIP_ENTRY_SIGNATURE, 0, 4, 'hex')
	fileHeader.write(ZIP_VERSION, 4, 2, 'hex')
	fileHeader.write(ZIP_FLAGS, 6, 2, 'hex')
	fileHeader.write(ZIP_COMPRESSION_DEFLATE, 8, 2, 'hex')
	mtime.copy(fileHeader, 10)
	mdate.copy(fileHeader, 12)
	crc.copy(fileHeader, 14)
	fileHeader.writeUIntLE(compressed_size, 18, 4)
	fileHeader.writeUIntLE(uncompressed_size, 22, 4)
	fileHeader.writeUIntLE(filename.length, 26, 2)
	fileHeader.writeUIntLE(ZIP_ENTRY_EXTRAFIELD_LEN, 28, 2)
	fileHeader.write(filename, 30, 'ascii')
	fileHeader.write(ZIP_ENTRY_EXTRAFIELD, 30 + filename.length, ZIP_ENTRY_EXTRAFIELD_LEN, 'hex')
	return fileHeader

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
createCDRecord = ({ filename, compressed_size, uncompressed_size, crc, mtime, mdate, fileHeaderOffset }) ->
	cd = new Buffer(centralDirectoryLength(filename))
	cd.write(ZIP_CD_SIGNATURE, 0, 4, 'hex')
	cd.write(ZIP_CD_VERSION, 4, 2, 'hex')
	cd.write(ZIP_VERSION, 6, 2, 'hex')
	cd.write(ZIP_FLAGS, 8, 2, 'hex')
	cd.write(ZIP_COMPRESSION_DEFLATE, 10, 2, 'hex')
	mtime.copy(cd, 12)
	mdate.copy(cd, 14)
	crc.copy(cd, 16)
	cd.writeUIntLE(compressed_size, 20, 4, 'hex')
	cd.writeUIntLE(uncompressed_size, 24, 4, 'hex')
	cd.writeUIntLE(filename.length, 28, 2)
	cd.writeUIntLE(ZIP_CD_EXTRAFIELD_LEN, 30, 2)
	cd.writeUIntLE(ZIP_CD_FILE_COMM_LEN, 32, 2)
	cd.writeUIntLE(ZIP_CD_DISK_START, 34, 2)
	cd.write(ZIP_CD_INTERNAL_ATT, 36, 2, 'hex')
	cd.write(ZIP_CD_EXTERNAL_ATT, 38, 4, 'hex')
	cd.writeUIntLE(fileHeaderOffset, 42, 4)
	cd.write(filename, 46, 'ascii')
	cd.write(ZIP_CD_EXTRAFIELD, 46 + filename.length, ZIP_CD_EXTRAFIELD_LEN, 'hex')
	return cd

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
	cd_offset = entries.reduce ((sum, x) -> sum + fileHeaderLength(x.filename) + x.compressed_size), 0
	cd_size = entries.reduce ((sum, x) -> sum + centralDirectoryLength(x.filename)), 0
	ecd = new Buffer(ZIP_ECD_SIZE)
	ecd.write(ZIP_ECD_SIGNATURE, 0, 4, 'hex')
	ecd.writeUIntLE(ZIP_ECD_DISK_NUM, 4, 2)
	ecd.writeUIntLE(ZIP_CD_DISK_START, 6, 2)
	ecd.writeUIntLE(entries.length, 8, 2)
	ecd.writeUIntLE(entries.length, 10, 2)
	ecd.writeUIntLE(cd_size, 12, 4)
	ecd.writeUIntLE(cd_offset, 16, 4)
	ecd.writeUIntLE(ZIP_ECD_COMM_LEN, 20, 2, 'hex')
	return ecd

dosFormatTime = (d) ->
	buf = new Buffer(2)
	buf.writeUIntLE((d.getSeconds() / 2) + (d.getMinutes() << 5) + (d.getHours() << 11), 0, 2)
	return buf

dosFormatDate = (d) ->
	buf = new Buffer(2)
	buf.writeUIntLE(d.getDate() + ((d.getMonth() + 1) << 5) + ((d.getFullYear() - 1980) << 9), 0, 2)
	return buf

getCombinedCrc = (parts) ->
	if parts.length == 1
		# crc32 is stored as a number, has to be transformed to a Buffer
		buf = new Buffer(4)
		buf.writeUInt32LE(parts[0].crc, 0, 4)
		return buf
	else
		crcUtils.crc32_combine_multi(parts).combinedCrc32[0..3]


exports.totalLength = totalLength = (entries) ->
	return ZIP_ECD_SIZE + entries.reduce ((sum, x) -> sum + x.zLen), 0

exports.createEntry = createEntry = (filename, parts, mdate) ->
	mdate ?= new Date()
	compressed_size = parts.reduce ((sum, x) -> sum + x.zLen), DEFLATE_END.length
	uncompressed_size = parts.reduce ((sum, x) -> sum + x.len), 0
	contentLength = fileHeaderLength(filename) + compressed_size
	entry =
		filename: filename
		compressed_size: compressed_size
		uncompressed_size: uncompressed_size
		crc: getCombinedCrc(parts)
		mtime: dosFormatTime(mdate)
		mdate: dosFormatDate(mdate)
		contentLength: contentLength
		fileHeaderOffset: null # known only after it is appended to the stream
		zLen: contentLength + centralDirectoryLength(filename)
		stream: CombinedStream.create()
	entry.stream.append(createFileHeader(entry))
	entry.stream.append(stream) for { stream } in parts
	entry.stream.append(DEFLATE_END)
	return entry

exports.create = create = (entries) ->
	out = CombinedStream.create()
	offset = 0
	for entry in entries
		entry.fileHeaderOffset = offset
		offset += entry.contentLength
		out.append(entry.stream)
	out.append(createCDRecord(entry)) for entry in entries
	out.append(createEndOfCDRecord(entries))
	out.zLen = totalLength(entries)
	return out

# DEPRECATED
# Single-entry zip archive backwards-compatibility
exports.createZip = (filename, parts, mdate) ->
	entry = createEntry(filename, parts, mdate)
	create([ entry ])
