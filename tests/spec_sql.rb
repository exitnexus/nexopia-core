lib_require :Core, "sql"

describe SqlBase do
    TEST_DATA_ROWS_SQL = 1500
    TEST_DATA_INSERT_SLICE_SQL = 200

    before(:all) do

        @id = 1
        @options = {
            :host => 'devdba',
            :login => 'root',
            :passwd => 'Ohio'
        }

        # setup dbs
        @options_single   = {:db => 'test_dev'}
        @options_stripe_1 = {:db => 'test1_1_dev'}
        @options_stripe_2 = {:db => 'test1_2_dev'}

        # copy common options
        @options.each_pair {|key,val|
            @options_single[key] = val
            @options_stripe_1[key] = val
            @options_stripe_2[key] = val
        }

        @options_stripe = {
            :children => {
                1 => @options_stripe_1,
                2 => @options_stripe_2
            }
        }
    end

    after(:all) do
    end

    before(:each) do
    end

    after(:each) do
        @single.close().should eql(true) if @single
        @stripe.close().should eql(true) if @stripe
    end

    def setup_db_single()
        config = SqlBase::Config.new(:options => @options_single)
        (@single = SqlDBmysql.new(:single, 1, config)).should be_kind_of(SqlDBmysql)
        @single.connect().should be(true)
    end

    def random_values()
        values = []
        TEST_DATA_ROWS_SQL.times {
            value = rand(2**16)
            values << "(#{@id},#{value},'#{value.to_s}')"
            @id += 1
        }
        return values
    end

    def create_and_populate_db_single()
        sql = "CREATE TEMPORARY TABLE tmp (
                id INT(10) NOT NULL AUTO_INCREMENT,
                num INT(10) NOT NULL,
                str TEXT NOT NULL,
                PRIMARY KEY (id)
              )"
        result = @single.query(sql)
        result.should be_kind_of(SqlDBmysql::DBResultMysql)

        random_values().each_slice(TEST_DATA_INSERT_SLICE_SQL) {|slice|
            sql = "INSERT INTO tmp (id,num,str) VALUES " + slice.join(",")
            result = @single.query(sql)
            result.should be_kind_of(SqlDBmysql::DBResultMysql)
            result.affected_rows().should eql(slice.length)
        }
    end

    def setup_db_stripe()
        config_1 = SqlBase::Config.new(:options => @options_stripe_1)
        config_2 = SqlBase::Config.new(:options => @options_stripe_2)
        config = SqlBase::Config.new(:children => {
            1 => [SqlDBmysql.new(:stripe_1, 1, config_1)],
            2 => [SqlDBmysql.new(:stripe_2, 1, config_2)]
        })

        (@stripe = SqlDBStripe.new(:stripe, 1, config)).should be_kind_of(SqlDBStripe)
        @stripe.dbs.each_value {|db| db.should be_kind_of(SqlDBmysql)}
        @stripe.connect().should be(true)
    end

    def create_and_populate_db_stripe()
        sql = "CREATE TEMPORARY TABLE tmp (
                id INT(10) NOT NULL AUTO_INCREMENT,
                num INT(10) NOT NULL,
                str TEXT NOT NULL,
                PRIMARY KEY (id)
              )"
        result = @stripe.query(sql)
        result.should be_kind_of(SqlDBStripe::StripeDBResult)

        random_values().each_slice(TEST_DATA_INSERT_SLICE_SQL) {|slice|
            sql = "INSERT IGNORE INTO tmp (id,num,str) VALUES " + slice.join(",")
            result = @stripe.query(sql)
            result.should be_kind_of(SqlDBStripe::StripeDBResult)
            result.affected_rows().should eql(slice.length * @stripe.dbs.length)
        }
    end

    it "children should have complete interface" do
        dbs = [ SqlDBmysql, SqlDBStripe ]
        results = [ SqlDBmysql::DBResultMysql, SqlDBStripe::StripeDBResult ]

        dbs.each {|db|
            db.method_defined?(:connect).should eql(true)
            db.method_defined?(:close).should eql(true)
            db.method_defined?(:query).should eql(true)
            db.method_defined?(:query_streamed).should eql(true)
            db.method_defined?(:list_indexes).should eql(true)
            db.method_defined?(:list_fields).should eql(true)
        }

        results.each {|result|
            result.method_defined?(:affected_rows).should eql(true)
            result.method_defined?(:total_rows).should eql(true)
            result.method_defined?(:num_rows).should eql(true)
            result.method_defined?(:each).should eql(true)
            result.method_defined?(:use_result).should eql(true)
            result.method_defined?(:store_result).should eql(true)
            result.method_defined?(:free).should eql(true)
            result.method_defined?(:empty?).should eql(true)
            result.method_defined?(:pending?).should eql(true)
        }

    end

    it "should connect and disconnect" do
        setup_db_single()
        setup_db_stripe()
    end

    it "should create and populate temporary table" do
        setup_db_single()
        setup_db_stripe()
        create_and_populate_db_single()
        create_and_populate_db_stripe()
    end

    it "should support basic single server operations" do
        setup_db_single()
        create_and_populate_db_single()

        sql = "SELECT num,str FROM tmp"
        result = @single.query(sql)
        result.should be_kind_of(SqlDBmysql::DBResultMysql)
        result.num_rows().should eql(result.total_rows())

        sql = "SELECT SQL_CALC_FOUND_ROWS num,str FROM tmp WHERE id < #{TEST_DATA_ROWS_SQL / 2} LIMIT 20"
        result = @single.query(sql)
        result.should be_kind_of(SqlDBmysql::DBResultMysql)
        result.num_rows().should_not eql(result.total_rows())
    end

    it "should support basic stripe server operations" do
        setup_db_stripe()
        create_and_populate_db_stripe()

        sql = "SELECT num,str FROM tmp"
        result = @stripe.query(sql)
        result.should be_kind_of(SqlDBStripe::StripeDBResult)
        result.num_rows().should eql(result.total_rows())

        sql = "SELECT SQL_CALC_FOUND_ROWS num,str FROM tmp WHERE id < #{TEST_DATA_ROWS_SQL / 2} LIMIT 20"
        result = @stripe.query(sql)
        result.should be_kind_of(SqlDBStripe::StripeDBResult)
        result.num_rows().should_not eql(result.total_rows())
    end

    it "should use and store query results as single server" do
        setup_db_single()
        create_and_populate_db_single()

        rows_before = []
        rows_streamed = []
        rows_after = []

        sql = "SELECT num,str FROM tmp WHERE id < #{TEST_DATA_ROWS_SQL / 2} ORDER BY num"

        result_before = @single.query(sql)
        result_before.should be_kind_of(SqlDBmysql::DBResultMysql)
        result_before.each {|row| rows_before << row['num']}

        result_streamed = @single.query_streamed(sql)
        result_streamed.should be_kind_of(SqlDBmysql::DBResultMysql)
        result_streamed.each {|row| rows_streamed << row['num']}
        # this shouldn't retrieve any additional rows
        result_streamed.each {|row| rows_streamed << row['num']}

        # check if we can query correctly after stream query
        result_after = @single.query(sql)
        result_after.should be_kind_of(SqlDBmysql::DBResultMysql)
        result_after.each {|row| rows_after << row['num']}

        # validate that replies are the same
        rows_before.length.should eql(rows_streamed.length)
        rows_before.length.should eql(rows_after.length)
        rows_before.length.times {|i| rows_before[i].should eql(rows_streamed[i])}
        rows_before.length.times {|i| rows_before[i].should eql(rows_after[i])}
    end

    it "should use and store query results as stripe server" do
        setup_db_stripe()
        create_and_populate_db_stripe()

        rows_before = []
        rows_streamed = []
        rows_after = []

        sql = "SELECT num,str FROM tmp WHERE id < #{TEST_DATA_ROWS_SQL / 2} ORDER BY num"

        result_before = @stripe.query(sql)
        result_before.should be_kind_of(SqlDBStripe::StripeDBResult)
        result_before.each {|row| rows_before << row['num']}

        result_streamed = @stripe.query_streamed(sql)
        result_streamed.should be_kind_of(SqlDBStripe::StripeDBResult)
        result_streamed.each {|row| rows_streamed << row['num']}
        # this shouldn't retrieve any additional rows
        result_streamed.each {|row| rows_streamed << row['num']}

        # check if we can query correctly after stream query
        result_after = @stripe.query(sql)
        result_after.should be_kind_of(SqlDBStripe::StripeDBResult)
        result_after.each {|row| rows_after << row['num']}

        # validate that replies are the same
        rows_before.length.should eql(rows_streamed.length)
        rows_before.length.should eql(rows_after.length)
        rows_before.length.times {|i| rows_before[i].should eql(rows_streamed[i])}
        rows_before.length.times {|i| rows_before[i].should eql(rows_after[i])}
    end

    it "should handle exceptions" do
        setup_db_single()
        setup_db_stripe()
        create_and_populate_db_single()
        create_and_populate_db_stripe()

        # in this query we have error
        sql = "SELECT SOMETHING num,str FROM tmp WHERE id < #{TEST_DATA_ROWS_SQL / 2} ORDER BY num"

        begin
            @single.query(sql)
        rescue SqlBase::SqlError
            $!.should be_kind_of(SqlBase::QueryError)
        end

        begin
            @stripe.query(sql)
        rescue SqlBase::SqlError
            $!.should be_kind_of(SqlBase::QueryError)
        end
    end

    it "should prohibit certain queries as stripe server" do
        setup_db_stripe()
        create_and_populate_db_stripe()

        blocked = [
            "INSERT INTO tmp (id, num, str) VALUE (15423, 43423, 'blocked')",
        ]
        allowed = [
            "INSERT IGNORE INTO tmp (id, num, str) VALUE (15435, 4433, 'allowed')",
        ]

        # check all blocked queries
        blocked.each {|sql|
            begin
                @stripe.query(sql)
            rescue SqlBase::SqlError
                $!.should be_kind_of(SqlBase::ParamError)
            end
        }

        # check all allowed queries
        allowed.each {|sql|
            @stripe.query(sql)
        }
    end

    it "should handle use and store query synchronization as single server" do
        setup_db_single()
        create_and_populate_db_single()

        rows_before = []
        rows_after = []

        sql = "SELECT num,str FROM tmp WHERE id < #{TEST_DATA_ROWS_SQL / 2} ORDER BY num"

        result_before = @single.query(sql)
        result_before.should be_kind_of(SqlDBmysql::DBResultMysql)
        result_before.each {|row| rows_before << row['num']}
        result_streamed = @single.query_streamed(sql)
        result_streamed.should be_kind_of(SqlDBmysql::DBResultMysql)

        # validate synchronization error, query after streamed query
        begin
            result_after = @single.query(sql)
            throw "Missing query synchronization exception"
        rescue SqlBase::CommandsSyncError
            $!.errno.should eql(Mysql::Error::CR_COMMANDS_OUT_OF_SYNC)
        ensure
        end

        # validate that connection is cleaned
        result_before = @single.query(sql)
        result_before.should be_kind_of(SqlDBmysql::DBResultMysql)
        result_before.each {|row| rows_after << row['num']}

        # validate results
        rows_before.length.should eql(rows_after.length)
        rows_before.length.times {|i| rows_before[i].should eql(rows_after[i])}
    end

    it "should handle use and store query synchronization as stripe server" do
        setup_db_stripe()
        create_and_populate_db_stripe()

        rows_before = []
        rows_after = []

        sql = "SELECT num,str FROM tmp WHERE id < #{TEST_DATA_ROWS_SQL / 2} ORDER BY num"

        result_before = @stripe.query(sql)
        result_before.should be_kind_of(SqlDBStripe::StripeDBResult)
        result_before.each {|row| rows_before << row['num']}
        result_streamed = @stripe.query_streamed(sql)
        result_streamed.should be_kind_of(SqlDBStripe::StripeDBResult)

        # validate synchronization error, query after streamed query
        begin
            result_after = @stripe.query(sql)
            throw "Missing query synchronization exception"
        rescue SqlBase::CommandsSyncError
            $!.errno.should eql(Mysql::Error::CR_COMMANDS_OUT_OF_SYNC)
        ensure
        end

        # validate that connection is cleaned
        result_after = @stripe.query(sql)
        result_after.should be_kind_of(SqlDBStripe::StripeDBResult)
        result_before.each {|row| rows_after << row['num']}

        # validate results
        rows_before.length.should eql(rows_after.length)
        rows_before.length.times {|i| rows_before[i].should eql(rows_after[i])}
    end

    it "should handle query cleanup correctly as single server" do
        setup_db_single()
        create_and_populate_db_single()

        sql = "SELECT num,str FROM tmp WHERE id < #{TEST_DATA_ROWS_SQL / 2} ORDER BY num"

        # validate manual cleanup of streamed query
        @single.query_streamed(sql).free
        @single.query(sql).should be_kind_of(SqlDBmysql::DBResultMysql)

        # validate cleanup after broken retrieval of rows
        result = @single.query_streamed(sql)
        result.should be_kind_of(SqlDBmysql::DBResultMysql)
        result.each {|row| break}

        # validate that query was cleaned
        @single.query(sql).should be_kind_of(SqlDBmysql::DBResultMysql)
    end

    it "should handle query cleanup correctly as stripe server" do
        setup_db_stripe()
        create_and_populate_db_stripe()

        sql = "SELECT num,str FROM tmp WHERE id < #{TEST_DATA_ROWS_SQL / 2} ORDER BY num"

        # validate manual cleanup of streamed query
        @stripe.query_streamed(sql).free
        @stripe.query(sql).should be_kind_of(SqlDBStripe::StripeDBResult)

        # validate cleanup after broken retrieval of rows
        result = @stripe.query_streamed(sql)
        result.should be_kind_of(SqlDBStripe::StripeDBResult)
        result.each {|row| break}

        # validate that query was cleaned
        @stripe.query(sql).should be_kind_of(SqlDBStripe::StripeDBResult)
    end
end

