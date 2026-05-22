Promise = require 'bluebird'
fs = Promise.promisifyAll(require 'fs')
path = require 'path'
{ expect } = require './utils/chai'
{ create, createZip, createEntry, createDeflatePart } = require '../index.coffee'

mdate = new Date(2016, 0, 1, 0, 0, 0) # use the same mdate in all tests

drain = (stream) ->
	new Promise (resolve, reject) ->
		chunks = []
		stream.on 'data', (chunk) ->
			chunks.push(chunk)
		stream.on 'end', ->
			resolve(Buffer.concat(chunks))
		stream.on('error', reject)
		stream.resume()

prepareTestPart = (path) ->
	new Promise (resolve, reject) ->
		part = createDeflatePart()
		fs.createReadStream(path)
		.on('error', reject)
		.pipe(part)
		.on('error', reject)
		.pipe(fs.createWriteStream("#{path}.deflate"))
		.on('error', reject)
		.on 'close', ->
			fs.writeFileSync("#{path}.json", JSON.stringify(part.metadata()))
			resolve()

describe 'createZip', ->
	# Each fixture is a folder with
	#     .txt files that have the uncompressed data of file-parts
	#     .txt.deflate files that have the compressed data of file-parts (created with createDeflatePart)
	#     .txt.json files that have file-part metadata (created with createDeflatePart)
	#     output.zip file that contains the expected zip (manually tested with standard zip/unzip commands)
	describe 'single entry', ->
		describe 'from a single part', ->
			before ->
				prepareTestPart('test/fixtures/single-entry/test.txt')

			it 'should create the expected zip file', ->
				part = require('./fixtures/single-entry/test.txt.json')
				part.stream = fs.createReadStream('test/fixtures/single-entry/test.txt.deflate')
				entry = createEntry('input.txt', [ part ], mdate)
				stream = create([ entry ])
				expect(stream.zLen).to.equal(fs.readFileSync('test/fixtures/single-entry/output.zip').length)
				drain(stream).then (data) ->
					expect(data).to.deep.equal(fs.readFileSync('test/fixtures/single-entry/output.zip'))

		describe 'from multiple parts', ->
			before ->
				Promise.all([
					prepareTestPart('test/fixtures/single-entry-parts/test1.txt')
					prepareTestPart('test/fixtures/single-entry-parts/test2.txt')
				])

			it 'should create the expected zip file', ->
				part1 = require('./fixtures/single-entry-parts/test1.txt.json')
				part1.stream = fs.createReadStream('test/fixtures/single-entry-parts/test1.txt.deflate')
				part2 = require('./fixtures/single-entry-parts/test2.txt.json')
				part2.stream = fs.createReadStream('test/fixtures/single-entry-parts/test2.txt.deflate')
				entry = createEntry('input.txt', [ part1, part2 ], mdate)
				stream = create([ entry ])
				expect(stream.zLen).to.equal(fs.readFileSync('test/fixtures/single-entry-parts/output.zip').length)
				drain(stream).then (data) ->
					expect(data).to.deep.equal(fs.readFileSync('test/fixtures/single-entry-parts/output.zip'))

	describe 'multiple entries', ->
		before ->
			Promise.all([
				prepareTestPart('test/fixtures/multiple-entries/foo1.txt')
				prepareTestPart('test/fixtures/multiple-entries/foo2.txt')
				prepareTestPart('test/fixtures/multiple-entries/hello1.txt')
				prepareTestPart('test/fixtures/multiple-entries/hello2.txt')
			])

		it 'should create the expected zip file', ->
			part1 = require('./fixtures/multiple-entries/foo1.txt.json')
			part1.stream = fs.createReadStream('test/fixtures/multiple-entries/foo1.txt.deflate')
			part2 = require('./fixtures/multiple-entries/foo2.txt.json')
			part2.stream = fs.createReadStream('test/fixtures/multiple-entries/foo2.txt.deflate')
			entry1 = createEntry('bar.txt', [ part1, part2 ], mdate)
			part3 = require('./fixtures/multiple-entries/hello1.txt.json')
			part3.stream = fs.createReadStream('test/fixtures/multiple-entries/hello1.txt.deflate')
			part4 = require('./fixtures/multiple-entries/hello2.txt.json')
			part4.stream = fs.createReadStream('test/fixtures/multiple-entries/hello2.txt.deflate')
			entry2 = createEntry('hello.txt', [ part3, part4 ], mdate)
			stream = create([ entry1, entry2 ])
			expect(stream.zLen).to.equal(fs.readFileSync('test/fixtures/multiple-entries/output.zip').length)
			drain(stream).then (data) ->
				expect(data).to.deep.equal(fs.readFileSync('test/fixtures/multiple-entries/output.zip'))

describe 'zip64 support', ->
	ZIP64_ECD_SIG = Buffer.from([ 0x50, 0x4b, 0x06, 0x06 ])
	ZIP64_LOCATOR_SIG = Buffer.from([ 0x50, 0x4b, 0x06, 0x07 ])
	ZIP64_MAGIC = 0xFFFFFFFF
	ZIP64_MAGIC16 = 0xFFFF

	describe 'forceZip64 option', ->
		describe 'single entry', ->
			before ->
				prepareTestPart('test/fixtures/single-entry/test.txt')

			it 'should produce output whose length matches zLen', ->
				part = require('./fixtures/single-entry/test.txt.json')
				part.stream = fs.createReadStream('test/fixtures/single-entry/test.txt.deflate')
				entry = createEntry('input.txt', [ part ], mdate, { forceZip64: true })
				stream = create([ entry ])
				drain(stream).then (data) ->
					expect(data.length).to.equal(stream.zLen)

			it 'should set zip64 flag on entry', ->
				part = require('./fixtures/single-entry/test.txt.json')
				part.stream = fs.createReadStream('test/fixtures/single-entry/test.txt.deflate')
				entry = createEntry('input.txt', [ part ], mdate, { forceZip64: true })
				expect(entry.zip64).to.be.true

			it 'should write zip64 extra field in local file header', ->
				part = require('./fixtures/single-entry/test.txt.json')
				part.stream = fs.createReadStream('test/fixtures/single-entry/test.txt.deflate')
				entry = createEntry('input.txt', [ part ], mdate, { forceZip64: true })
				stream = create([ entry ])
				drain(stream).then (data) ->
					# sizes in local file header are 0xFFFFFFFF (zip64 markers)
					expect(data.readUInt32LE(18)).to.equal(ZIP64_MAGIC)  # compressed size
					expect(data.readUInt32LE(22)).to.equal(ZIP64_MAGIC)  # uncompressed size
					# extra field length = 20 (4 tag+size + 16 two 8-byte values)
					expect(data.readUInt16LE(28)).to.equal(20)
					# extra field tag = 0x0001
					expect(data.readUInt16LE(30 + entry.filename.length)).to.equal(0x0001)
					# real uncompressed size stored in extra field (as little-endian 64-bit)
					expect(data.readUInt32LE(30 + entry.filename.length + 4)).to.equal(part.len)

			it 'should include Zip64 EOCD and locator records', ->
				part = require('./fixtures/single-entry/test.txt.json')
				part.stream = fs.createReadStream('test/fixtures/single-entry/test.txt.deflate')
				entry = createEntry('input.txt', [ part ], mdate, { forceZip64: true })
				stream = create([ entry ])
				drain(stream).then (data) ->
					expect(data.indexOf(ZIP64_ECD_SIG)).to.not.equal(-1)
					expect(data.indexOf(ZIP64_LOCATOR_SIG)).to.not.equal(-1)

			it 'should have 0xFFFF/0xFFFFFFFF markers in the regular EOCD', ->
				part = require('./fixtures/single-entry/test.txt.json')
				part.stream = fs.createReadStream('test/fixtures/single-entry/test.txt.deflate')
				entry = createEntry('input.txt', [ part ], mdate, { forceZip64: true })
				stream = create([ entry ])
				drain(stream).then (data) ->
					# regular EOCD is always the last 22 bytes
					eocdOffset = data.length - 22
					expect(data.readUInt16LE(eocdOffset + 8)).to.equal(ZIP64_MAGIC16)   # entries on disk
					expect(data.readUInt32LE(eocdOffset + 12)).to.equal(ZIP64_MAGIC)    # CD size
					expect(data.readUInt32LE(eocdOffset + 16)).to.equal(ZIP64_MAGIC)    # CD offset

		describe 'multiple entries', ->
			before ->
				Promise.all([
					prepareTestPart('test/fixtures/multiple-entries/foo1.txt')
					prepareTestPart('test/fixtures/multiple-entries/foo2.txt')
					prepareTestPart('test/fixtures/multiple-entries/hello1.txt')
					prepareTestPart('test/fixtures/multiple-entries/hello2.txt')
				])

			it 'should produce output whose length matches zLen', ->
				part1 = require('./fixtures/multiple-entries/foo1.txt.json')
				part1.stream = fs.createReadStream('test/fixtures/multiple-entries/foo1.txt.deflate')
				part2 = require('./fixtures/multiple-entries/foo2.txt.json')
				part2.stream = fs.createReadStream('test/fixtures/multiple-entries/foo2.txt.deflate')
				entry1 = createEntry('bar.txt', [ part1, part2 ], mdate, { forceZip64: true })
				part3 = require('./fixtures/multiple-entries/hello1.txt.json')
				part3.stream = fs.createReadStream('test/fixtures/multiple-entries/hello1.txt.deflate')
				part4 = require('./fixtures/multiple-entries/hello2.txt.json')
				part4.stream = fs.createReadStream('test/fixtures/multiple-entries/hello2.txt.deflate')
				entry2 = createEntry('hello.txt', [ part3, part4 ], mdate, { forceZip64: true })
				stream = create([ entry1, entry2 ])
				drain(stream).then (data) ->
					expect(data.length).to.equal(stream.zLen)

	describe 'automatic zip64 for large sizes', ->
		it 'should set zip64 when uncompressed size exceeds 4GB', ->
			part = { zLen: 2, len: ZIP64_MAGIC + 1, crc: 0, stream: fs.createReadStream('test/fixtures/single-entry/test.txt.deflate') }
			entry = createEntry('big.txt', [ part ], mdate)
			expect(entry.zip64).to.be.true

		it 'should not set zip64 for normal-sized files', ->
			part = require('./fixtures/single-entry/test.txt.json')
			part.stream = fs.createReadStream('test/fixtures/single-entry/test.txt.deflate')
			entry = createEntry('input.txt', [ part ], mdate)
			expect(entry.zip64).to.be.false
