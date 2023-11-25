namespace SchemaUpdater;

uses
  RemObjects.Common.Xml,
  RemObjects.Common.Json,
  RemObjects.DataAbstract,
  RemObjects.DataAbstract.Server,
  RemObjects.DataAbstract.Schema;

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


      var lConnectionManager := new ConnectionManager();
      (lConnectionManager as RemObjects.Common.Xml.IXmlSerializable).LoadFromFile(lConnectionsFile);

      var lSchema := new ServiceSchema;
      if lSchemaFileName.FileExists then begin
        lSchema.LoadFromFile(lSchemaFileName);
        Log($"Current file format is {lSchema.FileFormat}");
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

      var lConnectionDefinition := lConnectionManager.ConnectionDefinitions.FindItem(lConnectionName);


      var lConnection := lConnectionManager.AcquireConnection(lConnectionName);
      var lConnectionDriver := new ConnectionDriver(lConnectionDefinition.ConnectionString);

      var lDefaultConnectionType := "";//lConnection.ConnectionType;
      var lDefaultConnectionName := lConnection.Name;

      //
      // new tables
      //

      var lTableNames := lConnection.GetTableNames();
      for each t in lTableNames.OrderBy(t -> t)/*.Where(t -> t = "process_instance_logs")*/ do try

        var lTableName := t;
        if assigned(lParameters.Switches["strip-prefixes"]) then
          lTableName := String(lTableName).SubstringFromLastOccurrenceOf(".");
        var lDataTable := lSchema.DataTables.FirstOrDefault(d -> d.Name = lTableName);
        var lMetadata := lConnectionDriver.GetTableMetadata(t);

        if assigned(lDataTable) then begin

          Log($"Data Table '{lTableName}' exists in schema.");

          for each s in lDataTable.Statements do begin
            Log($"| Data Table Statement '{s.Name}'.");
            for each f in lMetadata.Fields do begin
              var lMapping := s.ColumnMappings.FirstOrDefault(cm -> cm.TableField = f.Name);
              if assigned(lMapping) then begin
                //Log($"| | Database Field '{lMapping.Name}' is present in schema.");
                var lField := lDataTable.Fields[lMapping.Name];
                if assigned(lField) then begin
                  if lField.DataType = f.DataType then begin
                    //Log($"| | Database Field '{lMapping.Name}' has correct type.");
                  end
                  else begin
                    Log($"| | Database Field '{lMapping.Name}' has wrong type ({lField.DataType}, should be {f.DataType}).");
                    lField.DataType := f.DataType;
                  end;
                end;

              end
              else begin
                Log($"| | Database Field '{f.Name}' missing in schema. Added");
                lDataTable.Fields.Add(f);
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

  end;

end.