part of sqljocky;

class _PrepareOkPacket {
  int _statementHandlerId;
  int _columnCount;
  int _parameterCount;
  int _warningCount;

  int get statementHandlerId => _statementHandlerId;
  int get columnCount => _columnCount;
  int get parameterCount => _parameterCount;
  int get warningCount => _warningCount;
  
  _PrepareOkPacket(Buffer buffer) {
    buffer.seek(1);
    _statementHandlerId = buffer.readInt32();
    _columnCount = buffer.readInt16();
    _parameterCount = buffer.readInt16();
    buffer.skip(1);
    _warningCount = buffer.readInt16();
  }
  
  String toString() {
    return "OK: statement handler id: $_statementHandlerId, columns: $_columnCount, "
    "parameters: $_parameterCount, warnings: $_warningCount";
  }
}
