using EcommerceApp.Infrastructure;
using EcommerceApp.Repositories;
using Npgsql;
using NpgsqlTypes;

namespace EcommerceApp;

/// <summary>
/// Unit of Work: одна транзакція PostgreSQL на кілька репозиторіїв.
/// Усі репозиторії, отримані з одного екземпляра, працюють в одному з'єднанні
/// й одній транзакції - або фіксуються разом (Commit), або скасовуються разом (Rollback).
/// </summary>
public interface IUnitOfWork : IAsyncDisposable
{
    IUserRepository Users { get; }
    IStoreRepository Stores { get; }
    IProductRepository Products { get; }
    ICartRepository Carts { get; }
    IOrderRepository Orders { get; }
    IReviewRepository Reviews { get; }

    /// <summary>Відкриває з'єднання, починає транзакцію та (за потреби) встановлює актора для аудиту.</summary>
    Task BeginAsync(long? actorUserId = null);

    /// <summary>Змінює користувача, від імені якого тригери пишуть updated_by / deleted_by / audit_log.</summary>
    Task SetActorAsync(long? actorUserId);

    Task CommitAsync();
    Task RollbackAsync();
}

public sealed class UnitOfWork : IUnitOfWork, IDbSession
{
    private readonly NpgsqlDataSource _dataSource;
    private NpgsqlConnection? _connection;
    private NpgsqlTransaction? _transaction;

    private IUserRepository? _users;
    private IStoreRepository? _stores;
    private IProductRepository? _products;
    private ICartRepository? _carts;
    private IOrderRepository? _orders;
    private IReviewRepository? _reviews;

    public UnitOfWork(NpgsqlDataSource dataSource) => _dataSource = dataSource;

    // Репозиторії створюються ліниво й діляться одним IDbSession (this)
    public IUserRepository Users => _users ??= new UserRepository(this);
    public IStoreRepository Stores => _stores ??= new StoreRepository(this);
    public IProductRepository Products => _products ??= new ProductRepository(this);
    public ICartRepository Carts => _carts ??= new CartRepository(this);
    public IOrderRepository Orders => _orders ??= new OrderRepository(this);
    public IReviewRepository Reviews => _reviews ??= new ReviewRepository(this);

    public async Task BeginAsync(long? actorUserId = null)
    {
        if (_transaction is not null)
            throw new InvalidOperationException("Transaction is already active.");

        _connection = await _dataSource.OpenConnectionAsync();
        _transaction = await _connection.BeginTransactionAsync();
        await SetActorAsync(actorUserId);
    }

    public async Task SetActorAsync(long? actorUserId)
    {
        // CALL sp_set_actor: значення діє до кінця поточної транзакції
        await using var cmd = CreateCommand("CALL sp_set_actor(@id)");
        cmd.Parameters.Add(new NpgsqlParameter("id", NpgsqlDbType.Bigint) { Value = (object?)actorUserId ?? DBNull.Value });
        await cmd.ExecuteNonQueryAsync();
    }

    // IDbSession: команда завжди прив'язана до активної транзакції
    public NpgsqlCommand CreateCommand(string sql)
    {
        if (_connection is null || _transaction is null)
            throw new InvalidOperationException("Call BeginAsync() before using repositories.");
        return new NpgsqlCommand(sql, _connection, _transaction);
    }

    public async Task CommitAsync()
    {
        if (_transaction is null)
            throw new InvalidOperationException("No active transaction.");
        await _transaction.CommitAsync();
        await ReleaseAsync();
    }

    public async Task RollbackAsync()
    {
        if (_transaction is null)
            return;
        await _transaction.RollbackAsync();
        await ReleaseAsync();
    }

    // Якщо Commit не викликали (виняток, return) - транзакція скасовується автоматично
    public async ValueTask DisposeAsync() => await RollbackAsync();

    private async Task ReleaseAsync()
    {
        if (_transaction is not null) await _transaction.DisposeAsync();
        if (_connection is not null) await _connection.DisposeAsync();
        _transaction = null;
        _connection = null;
    }
}
