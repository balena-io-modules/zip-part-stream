fs = require 'fs'
stream = require 'stream'

writeZip = (path, filename, filedata) ->
	# fileHeader = new Buffer(32)
	signature = '504b0304'
	version = '0a00'
	flags = '0000'
	methods =
		none: '0000'
		deflated: '0008'
	mtime = 'd76d'
	mdate = '3d48'
	crc32 = '27b4dd13' # TODO
	compressed_size = new Buffer(4)
	compressed_size.writeUIntLE(filedata.length, 0, 4)
	uncompressed_size = new Buffer(4)
	uncompressed_size.writeUIntLE(filedata.length, 0, 4)
	filename_len = new Buffer(2)
	filename_len.writeUIntLE(filename.length, 0, 2)
	extrafield_len = '1c00'
	extrafield = '5554090003456dab569a6dab5675780b000104e803000004e8030000'

	cd_signature = '504b0102'
	cd_version = '1e03'
	cd_extrafield_len = '1800'
	cd_file_comm_len = '0000'
	cd_disk_start = '0000'
	cd_internal_att = '0100' # ascii file, TODO: change it to zero for raw
	cd_external_att = '0000a481'
	cd_local_header_offset = '00000000'
	cd_extrafield = '5554050003456dab5675780b000104e803000004e8030000'

	ecd_signature = '504b0506'
	ecd_disk_num = '0000'
	ecd_cd_entries = '0100'
	ecd_file_entries = '0100'
	ecd_cd_size = '4e000000' # TODO
	ecd_cd_offset = new Buffer(4)
	ecd_cd_offset.writeUIntLE(0x26 + filename.length + 0x1c, 0, 4) # static + filename + extrafield
	ecd_comment_len = '0000'

	z = fs.createWriteStream(path)
	z.write(new Buffer(signature, 'hex'))
	z.write(new Buffer(version, 'hex'))
	z.write(new Buffer(flags, 'hex'))
	z.write(new Buffer(methods.none, 'hex'))
	z.write(new Buffer(mtime, 'hex'))
	z.write(new Buffer(mdate, 'hex'))
	z.write(new Buffer(crc32, 'hex'))
	z.write(new Buffer(compressed_size, 'hex'))
	z.write(new Buffer(uncompressed_size, 'hex'))
	z.write(filename_len)
	z.write(new Buffer(extrafield_len, 'hex'))
	z.write(new Buffer(filename, 'ascii'))
	z.write(new Buffer(extrafield, 'hex'))
	z.write(new Buffer(filedata, 'ascii'))
	z.write(new Buffer(cd_signature, 'hex'))
	z.write(new Buffer(cd_version, 'hex'))
	z.write(new Buffer(version, 'hex'))
	z.write(new Buffer(flags, 'hex'))
	z.write(new Buffer(methods.none, 'hex'))
	z.write(new Buffer(mtime, 'hex'))
	z.write(new Buffer(mdate, 'hex'))
	z.write(new Buffer(crc32, 'hex'))
	z.write(new Buffer(compressed_size, 'hex'))
	z.write(new Buffer(uncompressed_size, 'hex'))
	z.write(filename_len)
	z.write(new Buffer(cd_extrafield_len, 'hex'))
	z.write(new Buffer(cd_file_comm_len, 'hex'))
	z.write(new Buffer(cd_disk_start, 'hex'))
	z.write(new Buffer(cd_internal_att, 'hex'))
	z.write(new Buffer(cd_external_att, 'hex'))
	z.write(new Buffer(cd_local_header_offset, 'hex'))
	z.write(new Buffer(filename, 'ascii'))
	z.write(new Buffer(cd_extrafield, 'hex'))
	z.write(new Buffer(ecd_signature, 'hex'))
	z.write(new Buffer(ecd_disk_num, 'hex'))
	z.write(new Buffer(cd_disk_start, 'hex'))
	z.write(new Buffer(ecd_cd_entries, 'hex'))
	z.write(new Buffer(ecd_file_entries, 'hex'))
	z.write(new Buffer(ecd_cd_size, 'hex'))
	z.write(ecd_cd_offset)
	z.write(new Buffer(ecd_comment_len, 'hex'))

	z.end()

	z.on 'finish', ->
		console.log('done')

writeZip('test.zip', 'test.txt', 'foo bar\n')
