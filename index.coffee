fs = require 'fs'
stream = require 'stream'
_ = require 'lodash'
crcUtils = require 'resin-crc-utils'
CombinedStream = require 'combined-stream'
{ DeflateCRC32Stream } = require 'crc32-stream'
Promise = require 'bluebird'

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
ZIP_CD_INTERNAL_ATT = '0100' # ascii file, TODO: change it to zero for raw
ZIP_CD_EXTERNAL_ATT = '0000a481'
ZIP_CD_LOCAL_HEADER_OFFSET = 0
ZIP_CD_EXTRAFIELD = '5554050003456dab5675780b000104e803000004e8030000'
ZIP_CD_EXTRAFIELD_LEN = 0x18
ZIP_ECD_SIGNATURE = '504b0506'
ZIP_ECD_DISK_NUM = 0
ZIP_ECD_CD_ENTRIES = 1
ZIP_ECD_FILE_ENTRIES = 1
ZIP_ECD_COMM_LEN = 0

exports.createDeflatePart = createDeflatePart = (isLast) ->
	compress = new DeflateCRC32Stream()
	if not isLast
		compress.end = ->
			console.log('ended')
			compress.flush ->
				compress.emit('end')
	compress.metadata = ->
		crc: @digest()
		len: @size()
		zLen: @size(true)
	return compress

writeZip = (filename, parts) ->
	mtime = 'd76d'
	mdate = '3d48'
	crc = crcUtils.crc32_combine_multi(parts).combinedCrc32[0..3]
	compressed_size = _.sum(_.map(parts, 'zLen'))
	uncompressed_size = _.sum(_.map(parts, 'len'))

	fileHeader = new Buffer(30 + filename.length + ZIP_ENTRY_EXTRAFIELD_LEN)
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

	cd_size = 0x2e + filename.length + ZIP_CD_EXTRAFIELD_LEN
	cd = new Buffer(cd_size)
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

	ecd_cd_offset = fileHeader.length + compressed_size
	ecd = new Buffer(22)
	ecd.write(ZIP_ECD_SIGNATURE, 0, 4, 'hex')
	ecd.writeUIntLE(ZIP_ECD_DISK_NUM, 4, 2)
	ecd.writeUIntLE(ZIP_CD_DISK_START, 6, 2)
	ecd.writeUIntLE(ZIP_ECD_CD_ENTRIES, 8, 2)
	ecd.writeUIntLE(ZIP_ECD_FILE_ENTRIES, 10, 2)
	ecd.writeUIntLE(cd_size, 12, 4)
	ecd.writeUIntLE(ecd_cd_offset, 16, 4)
	ecd.writeUIntLE(ZIP_ECD_COMM_LEN, 20, 2, 'hex')

	out = CombinedStream.create()
	out.append(fileHeader)
	out.append(stream) for { stream } in parts
	out.append(cd)
	out.append(ecd)
	return out

parts = [ 'foo foo foo\n', 'bar bar\n' ]

Promise.all(parts)
.map (part, i) ->
	partialCrc = null
	new Promise (resolve, reject) ->
		dpart = createDeflatePart(i == parts.length - 1)
		dpart.pipe(fs.createWriteStream("/tmp/part-#{i}.part"))
		.on('close', -> resolve(dpart.metadata()))
		.on('error', reject)
		dpart.write(part)
		dpart.end()
	.then (metadata) ->
		metadata.stream = fs.createReadStream("/tmp/part-#{i}.part")
		return metadata
.then (metadata) ->
	zip = writeZip('foo.txt', metadata)
	zip.pipe(fs.createWriteStream('out.zip'))
.catch (err) ->
	console.log('error', err)

setTimeout(
	-> console.log('ha')
, 1000)

