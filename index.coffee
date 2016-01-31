crcUtils = require 'resin-crc-utils'
CombinedStream = require 'combined-stream'
{ DeflateCRC32Stream } = require 'crc32-stream'

# Zip constants, explained how they are used on each function.
ZIP_VERSION = '0a00'
ZIP_FLAGS = '0000'
ZIP_ENTRY_SIGNATURE = '504b0304'
ZIP_ENTRY_EXTRAFIELD = '5554090003456dab569a6dab5675780b000104e803000004e8030000'
ZIP_ENTRY_EXTRAFIELD_LEN = 0x1c
ZIP_COMPRESSION_DEFLATE = '0000'
ZIP_COMPRESSION_DEFLATE = '0800'
ZIP_CD_SIGNATURE = '504b0102'
ZIP_CD_VERSION = '1e03'
ZIP_CD_FILE_COMM_LEN = 0
ZIP_CD_DISK_START = 0
ZIP_CD_INTERNAL_ATT = '0100'
ZIP_CD_EXTERNAL_ATT = '0000a481'
ZIP_CD_LOCAL_HEADER_OFFSET = 0
ZIP_CD_EXTRAFIELD = '5554050003456dab5675780b000104e803000004e8030000'
ZIP_CD_EXTRAFIELD_LEN = 0x18
ZIP_ECD_SIGNATURE = '504b0506'
ZIP_ECD_DISK_NUM = 0
ZIP_ECD_CD_ENTRIES = 1
ZIP_ECD_FILE_ENTRIES = 1
ZIP_ECD_COMM_LEN = 0
ZIP_ECD_SIZE = 22

# Create a stream for a compressed partial file
# The stream has to be consumed first to generate metadata information.
# Metadata and contents (as a readable stream) can then be used on createZip.
#
# Parameters:
#     isLast: bool, if this is the last part of the file
exports.createDeflatePart = createDeflatePart = (isLast) ->
	compress = new DeflateCRC32Stream()
	if not isLast
		# DEFLATE streams are a series of blocks,
		# each having a bit that marks whether there are more blocks after it.
		#
		# When the stream receives an end call, it means input has finished
		# and that block is marked as final. If that happens, it won't be possible
		# to concatenate it with further compressed parts.
		#
		# Calling flush when end is called makes the stream not "know" the input
		# has ended at the time of flushing, and so the final block is marked as non-final.
		compress.end = ->
			compress.flush ->
				compress.emit('end')
	compress.metadata = ->
		crc: @digest()
		len: @size()
		zLen: @size(true)
	return compress

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
	fileHeader.write(mtime, 10, 2, 'hex')
	fileHeader.write(mdate, 12, 2, 'hex')
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
createCentralDirectory = ({ filename, compressed_size, uncompressed_size, crc, mtime, mdate }) ->
	cd = new Buffer(centralDirectoryLength(filename))
	cd.write(ZIP_CD_SIGNATURE, 0, 4, 'hex')
	cd.write(ZIP_CD_VERSION, 4, 2, 'hex')
	cd.write(ZIP_VERSION, 6, 2, 'hex')
	cd.write(ZIP_FLAGS, 8, 2, 'hex')
	cd.write(ZIP_COMPRESSION_DEFLATE, 10, 2, 'hex')
	cd.write(mtime, 12, 2, 'hex')
	cd.write(mdate, 14, 2, 'hex')
	crc.copy(cd, 16)
	cd.writeUIntLE(compressed_size, 20, 4, 'hex')
	cd.writeUIntLE(uncompressed_size, 24, 4, 'hex')
	cd.writeUIntLE(filename.length, 28, 2)
	cd.writeUIntLE(ZIP_CD_EXTRAFIELD_LEN, 30, 2)
	cd.writeUIntLE(ZIP_CD_FILE_COMM_LEN, 32, 2)
	cd.writeUIntLE(ZIP_CD_DISK_START, 34, 2)
	cd.write(ZIP_CD_INTERNAL_ATT, 36, 2, 'hex')
	cd.write(ZIP_CD_EXTERNAL_ATT, 38, 4, 'hex')
	cd.writeUIntLE(ZIP_CD_LOCAL_HEADER_OFFSET, 42, 4)
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
createEndOfCDRecord = ({ filename, compressed_size }) ->
	cd_offset = fileHeaderLength(filename) + compressed_size
	cd_size = centralDirectoryLength(filename)
	ecd = new Buffer(ZIP_ECD_SIZE)
	ecd.write(ZIP_ECD_SIGNATURE, 0, 4, 'hex')
	ecd.writeUIntLE(ZIP_ECD_DISK_NUM, 4, 2)
	ecd.writeUIntLE(ZIP_CD_DISK_START, 6, 2)
	ecd.writeUIntLE(ZIP_ECD_CD_ENTRIES, 8, 2)
	ecd.writeUIntLE(ZIP_ECD_FILE_ENTRIES, 10, 2)
	ecd.writeUIntLE(cd_size, 12, 4)
	ecd.writeUIntLE(cd_offset, 16, 4)
	ecd.writeUIntLE(ZIP_ECD_COMM_LEN, 20, 2, 'hex')
	return ecd

# Create a zip that has a single file,
# created from multiple parts that are already compressed.
#
# The use case is generating zip archive for a huge file
# that has only a small dynamic part. The static parts
# are pre-compressed, giving a huge speed boost.
#
# filename: the filename of the single generated file in the archive
# parts: list of metadata objects obtained from createDeflatePart streams
exports.createZip = createZip = (filename, parts) ->
	entry =
		filename: filename
		compressed_size: parts.reduce ((sum, x) -> sum + x.zLen), 0
		uncompressed_size: parts.reduce ((sum, x) -> sum + x.len), 0
		crc: crcUtils.crc32_combine_multi(parts).combinedCrc32[0..3]
		mtime: 'd76d'
		mdate: '3d48'

	out = CombinedStream.create()
	out.append(createFileHeader(entry))
	out.append(stream) for { stream } in parts
	out.append(createCentralDirectory(entry))
	out.append(createEndOfCDRecord(entry))
	out.zLen = fileHeaderLength(filename) + entry.compressed_size + centralDirectoryLength(filename) + ZIP_ECD_SIZE
	return out
