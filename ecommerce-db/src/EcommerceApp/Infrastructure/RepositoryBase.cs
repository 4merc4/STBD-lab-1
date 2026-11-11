using Npgsql;
using NpgsqlTypes;

namespace EcommerceApp.Infrastructure;

/// <summary>
/// Те, що UnitOfWork надає репозиторіям: команди, прив'язані до ПОТОЧНОЇ транзакції.
/// Репозиторії самі з'єднання не відкривають і транзакцій не керують.
/// </summary>
public interface IDbSession
{
    NpgsqlCommand CreateCommand(string sql);
}

/// <summary>
/// Спільна логіка репозиторіїв. Єдині два способи звернутися до БД:
///   * запис  -> CALL збережена_процедура(...)
///   * читання -> SELECT ... FROM розріз (view) / табличної функції
/// </summary>
public abstract class RepositoryBase
{
    private readonly IDbSession _session;

    protected RepositoryBase(IDbSession session) => _session = session;

    /// <summary>CALL процедури без вихідних значень.</summary>
    protected async Task CallAsync(string procedure, params object?[] args)
    {
        await using var cmd = _session.CreateCommand(BuildCall(procedure, args.Length));
        AddArguments(cmd, args);
        await cmd.ExecuteNonQueryAsync();
    }

    /// <summary>
    /// CALL процедури, остання INOUT-ознака якої повертає створений ідентифікатор (bigint).
    /// INOUT-параметр додається автоматично зі значенням NULL.
    /// </summary>
    protected async Task<long> CallForIdAsync(string procedure, params object?[] args)
    {
        await using var cmd = _session.CreateCommand(BuildCall(procedure, args.Length + 1));
        AddArguments(cmd, args);
        cmd.Parameters.Add(new NpgsqlParameter($"p{args.Length}", NpgsqlDbType.Bigint) { Value = DBNull.Value });

        // CALL з INOUT-параметром повертає один рядок із цим значенням
        var result = await cmd.ExecuteScalarAsync();
        return Convert.ToInt64(result);
    }

    /// <summary>SELECT із розрізу/функції з відображенням рядків у DTO.</summary>
    protected async Task<List<T>> QueryAsync<T>(
        string sql, Func<NpgsqlDataReader, T> map, params (string Name, object? Value)[] parameters)
    {
        await using var cmd = _session.CreateCommand(sql);
        foreach (var (name, value) in parameters)
            cmd.Parameters.AddWithValue(name, value ?? DBNull.Value);

        await using var reader = await cmd.ExecuteReaderAsync();
        var rows = new List<T>();
        while (await reader.ReadAsync())
            rows.Add(map(reader));
        return rows;
    }

    protected async Task<T?> QuerySingleAsync<T>(
        string sql, Func<NpgsqlDataReader, T> map, params (string Name, object? Value)[] parameters)
        where T : class
    {
        var rows = await QueryAsync(sql, map, parameters);
        return rows.FirstOrDefault();
    }

    private static string BuildCall(string procedure, int argCount)
    {
        var placeholders = string.Join(", ", Enumerable.Range(0, argCount).Select(i => $"@p{i}"));
        return $"CALL {procedure}({placeholders})";
    }

    private static void AddArguments(NpgsqlCommand cmd, object?[] args)
    {
        for (var i = 0; i < args.Length; i++)
            cmd.Parameters.AddWithValue($"p{i}", args[i] ?? DBNull.Value);
    }
}

/// <summary>Короткі методи читання колонок за назвою.</summary>
public static class ReaderExtensions
{
    public static long Long(this NpgsqlDataReader r, string col) => r.GetInt64(r.GetOrdinal(col));
    public static int Int(this NpgsqlDataReader r, string col) => r.GetInt32(r.GetOrdinal(col));
    public static string Str(this NpgsqlDataReader r, string col) => r.GetString(r.GetOrdinal(col));
    public static decimal Dec(this NpgsqlDataReader r, string col) => r.GetDecimal(r.GetOrdinal(col));
    public static bool Bool(this NpgsqlDataReader r, string col) => r.GetBoolean(r.GetOrdinal(col));
    public static float Float(this NpgsqlDataReader r, string col) => r.GetFloat(r.GetOrdinal(col));
    public static DateTime Time(this NpgsqlDataReader r, string col) => r.GetDateTime(r.GetOrdinal(col));

    public static long? LongN(this NpgsqlDataReader r, string col)
    { var i = r.GetOrdinal(col); return r.IsDBNull(i) ? null : r.GetInt64(i); }

    public static string? StrN(this NpgsqlDataReader r, string col)
    { var i = r.GetOrdinal(col); return r.IsDBNull(i) ? null : r.GetString(i); }

    public static decimal? DecN(this NpgsqlDataReader r, string col)
    { var i = r.GetOrdinal(col); return r.IsDBNull(i) ? null : r.GetDecimal(i); }

    public static DateTime? TimeN(this NpgsqlDataReader r, string col)
    { var i = r.GetOrdinal(col); return r.IsDBNull(i) ? null : r.GetDateTime(i); }
}
