lib_require :Core, 'storable/storable'

describe Storable do
    TEST_DATA_ROWS_STORABLE = 150
    TEST_DATA_INSERT_SLICE_STORABLE = 200

    before(:all) do

        @id = 1
        @stats = {}

        @options = {
            :host => 'devdba',
            :login => 'root',
            :passwd => 'Ohio'
        }

        # setup dbs
        @options_single   = {:db => 'test_dev'}
        @options_stripe_1 = {:db => 'test1_1_dev'}
        @options_stripe_2 = {:db => 'test1_2_dev'}
        @options_stripe_3 = {:db => 'test1_3_dev'}

        # copy common options
        @options.each_pair {|key,val|
            @options_single[key] = val
            @options_stripe_1[key] = val
            @options_stripe_2[key] = val
            @options_stripe_3[key] = val
        }

        @options_stripe = {
            :children => {
                1 => @options_stripe_1,
                2 => @options_stripe_2,
                3 => @options_stripe_3
            }
        }

        @color_enum_map = {
            :colormap => {
                :blank => 0,
                :red => 1,
                :green => 2,
                :blue => 3
            }
        }
    end

    after(:all) do
    end

    before(:each) do
        create()
        populate(@single, @stripe)

        $single_storable_db = @single
        $stripe_storable_db = @stripe
        $color_enum_map = @color_enum_map

        Object.send(:remove_const, :SingleStorable) if Object.const_defined?(:SingleStorable)
        class SingleStorable < Storable
            init_storable($single_storable_db, :tmp, $color_enum_map)
        end

        Object.send(:remove_const, :StripeStorable) if Object.const_defined?(:StripeStorable)
        class StripeStorable < Storable
            init_storable($stripe_storable_db, :tmp, $color_enum_map)
        end
    end

    after(:each) do
        $single_storable_db = nil
        $stripe_storable_db = nil
        $color_enum_map = nil
    end

    def create
        sql = "CREATE TEMPORARY TABLE tmp (
                id INT(10) NOT NULL AUTO_INCREMENT,
                num INT(10) NOT NULL,
                color ENUM('blank', 'red', 'green', 'blue') NOT NULL DEFAULT 'blank',
                colormap TINYINT(4) NOT NULL,
                str TEXT NOT NULL,
                PRIMARY KEY (id)
              )".tr("\n", " ").squeeze(" ")

        config = SqlBase::Config.new(:options => @options_single)
        (@single = SqlDBmysql.new(:single, 1, config)).should be_kind_of(SqlDBmysql)

        result = @single.query(sql)
        result.should be_kind_of(SqlDBmysql::DBResultMysql)

        config_1 = SqlBase::Config.new(:options => @options_stripe_1)
        config_2 = SqlBase::Config.new(:options => @options_stripe_2)
        config_3 = SqlBase::Config.new(:options => @options_stripe_3)
        config = SqlBase::Config.new(:children => {
            1 => [SqlDBmysql.new(:stripe_1, 1, config_1)],
            2 => [SqlDBmysql.new(:stripe_2, 1, config_2)],
            3 => [SqlDBmysql.new(:stripe_3, 1, config_3)]
        })

        (@stripe = SqlDBStripe.new(:stripe, 1, config)).should be_kind_of(SqlDBStripe)
        @stripe.dbs.each_value {|db| db.should be_kind_of(SqlDBmysql)}

        result = @stripe.query(sql)
        result.should be_kind_of(SqlDBStripe::StripeDBResult)
    end

    def random_values
        values = []
        TEST_DATA_ROWS_STORABLE.times {
            value = rand(2**16)
            values << "(#{@id},#{value},'#{value.to_s}')"
            @id += 1
        }
        return values
    end

    def populate(*dbs)
        raise "No dbs to populate" unless dbs
        random_values().each_slice(TEST_DATA_INSERT_SLICE_STORABLE) {|slice|
            sql = "INSERT IGNORE INTO tmp (id,num,str) VALUES " + slice.join(",")

            dbs.each {|db|
                case db
                when SqlDBmysql then
                    result = db.query(sql)
                    result.should be_kind_of(SqlDBmysql::DBResultMysql)
                    result.affected_rows().should eql(slice.length)
                when SqlDBStripe then
                    result = db.query(sql)
                    result.should be_kind_of(SqlDBStripe::StripeDBResult)
                    result.affected_rows().should eql(slice.length * db.dbs.length)
                else
                    raise "Unknown db type (#{db.class.name}) to populate"
                end
            }
        }
    end

    it "should correctly initialize" do
    end

    it "should find with :scan" do
        (result = SingleStorable.find(:scan)).should be_kind_of(StorableResult)
        result.each {|row| row.should be_kind_of(Storable)}
        (result = StripeStorable.find(:scan)).should be_kind_of(StorableResult)
        result.each {|row| row.should be_kind_of(Storable)}
    end

    it "should find with :scan streamable" do
        (result_single = SingleStorable.find(:scan, :order => "id")).should be_kind_of(StorableResult)
        (result_stripe = StripeStorable.find(:scan, :order => "id")).should be_kind_of(StorableResult)

        # validate that results are the same for both storable types
        index = 0
        SingleStorable.find(:scan, :order => "id") {|row|
            row.should be_kind_of(SingleStorable)
            row.should eql(result_single[index])
            index += 1
        }

        index = 0
        StripeStorable.find(:scan, :order => "id") {|row|
            row.should be_kind_of(StripeStorable)
            row.should eql(result_stripe[index])
            index += 1
        }
    end

    it "should not process not supported options with streamable query" do
        SingleStorable.find(:scan, :promise) {|row| row.should_not be_kind_of(SingleStorable)}
        SingleStorable.find(:scan, :force_proxy) {|row| row.should_not be_kind_of(SingleStorable)}
        SingleStorable.find(:scan, :refresh) {|row| row.should_not be_kind_of(SingleStorable)}
        SingleStorable.find(:scan, :count) {|row| row.should_not be_kind_of(SingleStorable)}
        SingleStorable.find(:scan, :total_rows) {|row| row.should_not be_kind_of(SingleStorable)}
        SingleStorable.find(:scan, :calc_rows) {|row| row.should_not be_kind_of(SingleStorable)}
    end

    it "should handle :scan streamable cleanup" do
        # break find
        SingleStorable.find(:scan) {|row| break}
        StripeStorable.find(:scan) {|row| break}

        # try executing other :scan queries
        SingleStorable.find(:scan)
        StripeStorable.find(:scan)
        SingleStorable.find(:scan) {|row| row.should be_kind_of(SingleStorable)}
        StripeStorable.find(:scan) {|row| row.should be_kind_of(StripeStorable)}
    end

    it "should support find :conditions options" do
        # validate array and string conditions
        result_single_array = SingleStorable.find(:conditions => ["num > ?", 1000], :order => "id")
        result_single_array.should be_kind_of(StorableResult)
        result_stripe_array = StripeStorable.find(:conditions => ["num > ?", 1000], :order => "id")
        result_stripe_array.should be_kind_of(StorableResult)

        result_single_string = SingleStorable.find(:conditions => "num > 1000", :order => "id")
        result_single_string.should be_kind_of(StorableResult)
        result_stripe_string = StripeStorable.find(:conditions => "num > 1000", :order => "id")
        result_stripe_string.should be_kind_of(StorableResult)

        result_single_array.length.should eql(result_single_string.length)
        result_single_array.each_with_index {|row, i| row.should eql(result_single_string[i])}
        result_stripe_array.length.should eql(result_stripe_string.length)
        result_stripe_array.each_with_index {|row, i| row.should eql(result_stripe_string[i])}
    end

    it "should support find options" do
        # validate simple :fist
        SingleStorable.find(5,10,15,20, :first).should be_kind_of(SingleStorable)
        StripeStorable.find(5,10,15,20, :first).should be_kind_of(StripeStorable)

        first_single_flag = false
        SingleStorable.find(5,10,15,20, :first) {|row|
            first_single_flag.should be(false)
            row.should be_kind_of(SingleStorable)
            first_single_flag = true
        }

        first_stripe_flag = false
        StripeStorable.find(5,10,15,20, :first) {|row|
            first_stripe_flag.should be(false)
            row.should be_kind_of(StripeStorable)
            first_stripe_flag = true
        }

        # validate :conditions :first
        SingleStorable.find(:first, :conditions => "num > 1000").should be_kind_of(SingleStorable)
        StripeStorable.find(:first, :conditions => "num > 1000").should be_kind_of(StripeStorable)

        first_single_flag = false
        SingleStorable.find(:first, :conditions => "num > 1000") {|row|
            first_single_flag.should be(false)
            row.should be_kind_of(SingleStorable)
            first_single_flag = true
        }

        first_stripe_flag = false
        StripeStorable.find(:first, :conditions => "num > 1000") {|row|
            first_stripe_flag.should be(false)
            row.should be_kind_of(StripeStorable)
            first_stripe_flag = true
        }
    end

=begin
    it "should support column removal when storing unmodified value and deleting" do
        # remove column from database
        SingleStorable.db.query("ALTER TABLE tmp DROP COLUMN num")

        # check insert
        storable = SingleStorable.new
        storable.str = "insert"
        storable.store

        # validate that row was inserted
        SingleStorable.find(storable.id, :first).str.should eql("insert")

        # check update
        storable = SingleStorable.find(:first, :scan)
        storable.str = "update"
        storable.store

        # validate that row was inserted
        SingleStorable.find(storable.id, :first).str.should eql("update")

        # validate deletion with primary index
        SingleStorable.find(storable.id, :first).delete
        SingleStorable.find(storable.id, :first).should eql(nil)

        # create table without primary index
        @single.query("DROP TEMPORARY TABLE tmp").should be_kind_of(SqlDBmysql::DBResultMysql)
        sql = "CREATE TEMPORARY TABLE tmp (
                id INT(10) NOT NULL,
                num INT(10) NOT NULL,
                color ENUM('blank', 'red', 'green', 'blue') NOT NULL DEFAULT 'blank',
                colormap TINYINT(4) NOT NULL,
                str TEXT NOT NULL
              )".tr("\n", " ").squeeze(" ")
        @single.query(sql).should be_kind_of(SqlDBmysql::DBResultMysql)
        populate(@single)

        # reinitialize storable
        Object.send(:remove_const, :SingleStorable)
        class SingleStorable < Storable
            init_storable($single_storable_db, :tmp, $color_enum_map)
        end

        # validate deletion without primary index
        SingleStorable.db.query("ALTER TABLE tmp DROP COLUMN num")
        storable = SingleStorable.find(:first, :scan)
        storable.delete
        SingleStorable.find(storable.id, :first).should eql(nil)
    end
=end
end

