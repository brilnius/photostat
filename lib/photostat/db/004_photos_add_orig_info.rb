Sequel.migration do
  change do
    alter_table :photos do
      add_column :orig_path, String, :default => nil, :null => true
      add_column :orig_name, String, :default => nil, :null => true
    end
  end
end
