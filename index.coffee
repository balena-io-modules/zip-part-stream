fs = require 'fs'
stream = require 'stream'

ZIP_VERSION = '0a00'
ZIP_FLAGS = '0000'
ZIP_ENTRY_SIGNATURE = '504b0304'
ZIP_ENTRY_EXTRAFIELD = '5554090003456dab569a6dab5675780b000104e803000004e8030000'
ZIP_ENTRY_EXTRAFIELD_LEN = 0x1c
ZIP_COMPRESSION_NONE = '0000'
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

writeZip = (path, filename, filedata) ->
	mtime = 'd76d'
	mdate = '3d48'
	crc32 = '27b4dd13' # TODO
	compressed_size = filedata.length
	uncompressed_size = filedata.length
	fileHeader = new Buffer(30 + filename.length + ZIP_ENTRY_EXTRAFIELD_LEN)
	fileHeader.write(ZIP_ENTRY_SIGNATURE, 0, 4, 'hex')
	fileHeader.write(ZIP_VERSION, 4, 2, 'hex')
	fileHeader.write(ZIP_FLAGS, 6, 2, 'hex')
	fileHeader.write(ZIP_COMPRESSION_NONE, 8, 2, 'hex')
	fileHeader.write(mtime, 10, 2, 'hex')
	fileHeader.write(mdate, 12, 2, 'hex')
	fileHeader.write(crc32, 14, 4, 'hex')
	fileHeader.writeUIntLE(compressed_size, 18, 4)
	fileHeader.writeUIntLE(compressed_size, 22, 4)
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
	cd.write(ZIP_COMPRESSION_NONE, 10, 2, 'hex')
	cd.write(mtime, 12, 2, 'hex')
	cd.write(mdate, 14, 2, 'hex')
	cd.write(crc32, 16, 4, 'hex')
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

	ecd_cd_offset = fileHeader.length + filedata.length
	ecd = new Buffer(22)
	ecd.write(ZIP_ECD_SIGNATURE, 0, 4, 'hex')
	ecd.writeUIntLE(ZIP_ECD_DISK_NUM, 4, 2)
	ecd.writeUIntLE(ZIP_CD_DISK_START, 6, 2)
	ecd.writeUIntLE(ZIP_ECD_CD_ENTRIES, 8, 2)
	ecd.writeUIntLE(ZIP_ECD_FILE_ENTRIES, 10, 2)
	ecd.writeUIntLE(cd_size, 12, 4)
	ecd.writeUIntLE(ecd_cd_offset, 16, 4)
	ecd.writeUIntLE(ZIP_ECD_COMM_LEN, 20, 2, 'hex')


	z = fs.createWriteStream(path)
	z.write(fileHeader)
	z.write(new Buffer(filedata, 'ascii'))
	z.write(cd)
	z.write(ecd)

	z.end()

	z.on 'finish', ->
		console.log('done')

writeZip('test.zip', 'test.txt', 'foo bar\n')
