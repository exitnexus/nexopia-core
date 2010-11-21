describe Template do
	it "can instantiate a template" do
		t = Template::instance('core', 'test_template_1')
		t.display.should eql('empty')
	end
	
	it "can strip whitespace" do
		t = Template::instance('core', 'test_template_2')
		t.lines = [1, 2, 3, 4]
		t.display.should eql('1<br />2<br />3<br />4<br />')
	end
end
