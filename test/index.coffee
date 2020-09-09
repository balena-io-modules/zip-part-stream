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
