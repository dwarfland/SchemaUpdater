namespace SchemaUpdater;

uses
  RemObjects.DataAbstract,
  RemObjects.DataAbstract.Xml,
  RemObjects.DataAbstract.Server,
  RemObjects.DataAbstract.Schema,
  RemObjects.Elements.RTL;

uses
  RemObjects.DataAbstract.ConnectionDriver;

type
  Program = class
  public

    class method Main(args: array of String): Int32;
    begin
      // add your own code here
      writeLn('The magic happens here.');

      var lParameters := new SimpleCommandLineParser(args);
      var lSchemaFileName := lParameters.Switches["schema"];
      var lConnectionsFile := lParameters.Switches["connections"];
      var lConnectionName := lParameters.Switches["connection-name"];

      var lTargetFile := lParameters.Switches["save-as"];


      if length(lConnectionsFile) = 0 then
        lConnectionsFile := Path.FirstFileThatExists(Path.ChangeExtension(lSchemaFileName, ".daConnections"));

      if length(lConnectionsFile) = 0 then begin
        writeLn("Name for .daConnections file must be specified with --connections switch, if it cannot be derrived from the schema name.");
        exit 1;
      end;

      var lConnectionManager := new ConnectionManager();
      (lConnectionManager as IXmlSerializable).LoadFromFile(lConnectionsFile);

      var lSchema := new ServiceSchema;
      if lSchemaFileName.FileExists then begin
        lSchema.LoadFromFile(lSchemaFileName);
        Log($"Current file format is {lSchema.FileFormat}");
        if assigned(lSchema.Namespace) then
          Log($"Namespace is {lSchema.Namespace}");
      end
      else if assigned(lParameters.Switches["create"]) then begin
        lSchema.FileFormat := SerializableFormat.Json;
      end
      else begin
        writeLn($"File {lSchemaFileName} does not exist.");
        writeLn();
        exit 1;
      end;


      RemObjects.DataAbstract.Server.Configuration.Load;

      if (length(lConnectionName) = 0) and (lConnectionManager.ConnectionDefinitions.Count = 1)  then
        lConnectionName := lConnectionManager.ConnectionDefinitions.First.Name;

      if (length(lConnectionName) = 0) then begin
        writeLn("Connection name must be specified with --connection-name switch, if more than one connection is defined");
        exit 1;
      end;

      var lConnectionDefinition := lConnectionManager.ConnectionDefinitions.FindItem(lConnectionName);


      var lConnection := lConnectionManager.AcquireConnection(lConnectionName);
      var lConnectionDriver := new ConnectionDriver(lConnectionDefinition.ConnectionString);

      var lDefaultConnectionType := "";//lConnection.ConnectionType;
      var lDefaultConnectionName := lConnection.Name;

      var lSubTypes := GetNpgsqlSubTypes(lConnection.ConnectionString);

      //
      // new tables
      //

      var lTableNames := lConnection.GetTableNames();
      for each t in lTableNames.OrderBy(t -> t)/*.Wheresuperr(t -> t = "process_instance_logs")*/ do try

        var lTableName := t;
        if assigned(lParameters.Switches["strip-prefixes"]) then
          lTableName := String(lTableName).SubstringFromLastOccurrenceOf(".");

        //if lTableName ≠ "filetypes" then
          //continue;

        var lDataTable := lSchema.DataTables.FirstOrDefault(d -> d.Name = lTableName);
        var lMetadata := lConnectionDriver.GetTableMetadata(t);

        if assigned(lDataTable) then begin
          Log($"Data Table '{lTableName}' exists in schema.");

          for each s in lDataTable.Statements do begin
            Log($"| Data Table Statement '{s.Name}'.");

            for each f in lMetadata.Fields do begin

              var lSubType := lSubTypes[$"{lTableName}|{f.Name}"];
              if lSubType not in ["json", "jsonb", ""] then
                lSubType := nil;

              var lMapping := s.ColumnMappings.FirstOrDefault(cm -> cm.TableField = f.Name);
              if assigned(lMapping) then begin
                //Log($"| | Database Field '{lMapping.Name}' is present in schema.");
                var lField := if lDataTable.Fields.Contains(lMapping.Name) then lDataTable.Fields[lMapping.Name];
                if assigned(lField) then begin

                  if lField.DataType = f.DataType then begin
                    //Log($"| | Database Field '{lMapping.Name}' has correct type.");
                    if lField.DataType in [DataType.String,DataType.WideString] then begin
                      if lField.Size ≠ f.Size then begin
                        Log($"| | Database Field '{lMapping.Name}' has wrong size ({lField.Size}, should be {f.Size}).");
                        lField.Size := f.Size;
                      end;
                    end;
                  end
                  else begin
                    Log($"| | Database Field '{lMapping.Name}' has wrong type ({lField.DataType}, should be {f.DataType}).");
                    lField.DataType := f.DataType;
                    if lField.DataType in [DataType.String,DataType.WideString] then
                      lField.Size := f.Size;
                    lField.Required := f.Required;
                  end;
                  lField.Required := f.Required;
                  if assigned(lSubType) then
                    lField.CustomAttributes := "subtype="+lSubType;

                end
                else begin
                  Log($"| | Database Field '{f.Name}' was mapped, but is missing in schema. Added.");
                  f.Name := lMapping.Name;
                  lDataTable.Fields.Add(f);
                  if assigned(lSubType) then
                    f.CustomAttributes := "subtype="+lSubType;
                end;

              end
              else begin
                Log($"| | Database Field '{f.Name}' missing in schema. Added");
                lDataTable.Fields.Add(f);
                if assigned(lSubType) then
                  f.CustomAttributes := "subtype="+lSubType;
                s.ColumnMappings.Add(new SchemaColumnMapping(f.Name, f.Name, f.Name));
              end;
            end;

            for each cm in s.ColumnMappings.ToList do begin
              var lField := lMetadata.Fields.FirstOrDefault(f -> f.Name = cm.TableField);
              if assigned(lField) then begin
                //Log($"| | Schema Field '{cm.Name}' is good.");
              end
              else begin
                Log($"| | Schema Field '{cm.Name}' missing in database. Removed");
                lDataTable.Fields.Remove(cm.Name);
                var lMapping := s.ColumnMappings.FirstOrDefault(cm2 -> cm2.TableField = cm.Name);
                s.ColumnMappings.Remove(cm);
              end;
            end;
          end;

          //Log($"Data Table '{t}' found");
        end
        else begin
          Log($"Data Table '{lTableName}' missing in schema.");

          var lSchemaTable := new SchemaDataTable();
          lSchemaTable.Name := lTableName;//RemObjects.DataAbstract.SchemaModeler.SchemaItemHelpers.GetCleanName(lTableName);
          lSchemaTable.IsPublic := true;

          var lStatement := new SchemaSQLStatement();
          if length(lDefaultConnectionType) = 0 then
            lStatement.Connection := lDefaultConnectionName
          else
            lStatement.ConnectionType := lDefaultConnectionType;

          lStatement.StatementType := StatementType.AutoSQL;
          lStatement.TargetTable := t;

          for each f in lMetadata.Fields do begin
            lSchemaTable.Fields.Add(f);
            lStatement.ColumnMappings.Add(new SchemaColumnMapping(f.Name, f.Name, f.Name));
            Log($"| Field {f.Name}: {f.DataType} added.");
          end;

          lSchemaTable.Statements.Add(lStatement);
          lSchema.DataTables.Add(lSchemaTable);
        end;

      except
        on E: Exception do
          writeLn($"Exception {E}");
      end;

      //
      // dropped tables
      //

      for each dt in lSchema.DataTables.ToList do begin
        var lDataTable := lTableNames.FirstOrDefault(t -> (t = dt.Name) or (String(t).SubstringFromLastOccurrenceOf(".") = dt.Name));

        if assigned(lDataTable) then begin
          //Log($"Data Table '{dt}' found");
        end
        else begin
          Log($"Data Table '{dt}' missing in database. Removed.");
          lSchema.DataTables.Remove(dt);
        end;

      end;

      //
      // Save
      //

      case caseInsensitive(lParameters.Switches["format"]) of
        "json": lSchema.FileFormat := SerializableFormat.Json;
        "xml": lSchema.FileFormat := SerializableFormat.Xml;
      end;
      lSchema.SaveToFile(coalesce(lTargetFile, lSchemaFileName));

    end;

    class method GetNpgsqlSubTypes(aConnectionString: String): Dictionary<String,String>;
    begin
      result := new;
      using lConnection := new Npgsql.NpgsqlConnection(aConnectionString.SubstringFromFirstOccurrenceOf("?")) do begin
        lConnection.Open();

        var lQuery := 'SELECT table_name, column_name, udt_name FROM information_schema.columns';

        using lCommand := new Npgsql.NpgsqlCommand(lQuery, lConnection) do begin
          using lReader := lCommand.ExecuteReader() do begin
            while lReader.Read() do begin
              var lTableName := lReader.GetString(0);
              var lColumnName := lReader.GetString(1);
              var lSubType := lReader.GetString(2); // 'jsonb', 'text', 'int4', etc.
              result[$"{lTableName}|{lColumnName}"] := lSubType;
              //Log($'Column: {lTableName}.{lColumnName}, Type: {lSubType}');
            end;
          end;
        end;
      end;
    end;

  end;

end.