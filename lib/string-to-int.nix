let
  stringToInt = input:
    let
      inputString = assert ((builtins.typeOf input) == "string"); input;
      value = builtins.fromJSON inputString;
    in
      assert ((builtins.typeOf value) == "int"); value;
in
stringToInt
