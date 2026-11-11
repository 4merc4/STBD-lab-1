using EcommerceApp.Infrastructure;
using EcommerceApp.Models;
using Npgsql;

namespace EcommerceApp.Repositories;

public sealed class StoreRepository : RepositoryBase, IStoreRepository
{
    private const string StoreSelect = @"
        SELECT id, name, slug, currency, is_active, owner_name, updated_at, updated_by
          FROM v_stores_active";

    public StoreRepository(IDbSession session) : base(session) { }

    public async Task<IReadOnlyList<StoreDto>> GetActiveAsync()
        => await QueryAsync(StoreSelect + " ORDER BY id", MapStore);

    public Task<StoreDto?> GetBySlugAsync(string slug)
        => QuerySingleAsync(StoreSelect + " WHERE lower(slug) = lower(@slug)", MapStore, ("slug", slug));

    public async Task<IReadOnlyList<ShippingMethodDto>> GetShippingMethodsAsync(long storeId)
        => await QueryAsync(
            @"SELECT shipping_method_id, store_id, name, base_cost, estimated_days
                FROM v_shipping_methods_active WHERE store_id = @store ORDER BY shipping_method_id",
            r => new ShippingMethodDto(r.Long("shipping_method_id"), r.Long("store_id"), r.Str("name"),
                                       r.Dec("base_cost"), r.Int("estimated_days")),
            ("store", storeId));

    public async Task<IReadOnlyList<StoreSalesDto>> GetSalesSummaryAsync()
        => await QueryAsync(
            "SELECT store_id, store_name, orders_count, revenue, avg_order_value FROM v_store_sales_summary ORDER BY store_id",
            r => new StoreSalesDto(r.Long("store_id"), r.Str("store_name"), r.Long("orders_count"),
                                   r.Dec("revenue"), r.Dec("avg_order_value")));

    private static StoreDto MapStore(NpgsqlDataReader r) => new(
        r.Long("id"), r.Str("name"), r.Str("slug"), r.Str("currency"), r.Bool("is_active"),
        r.Str("owner_name"), r.TimeN("updated_at"), r.LongN("updated_by"));
}
