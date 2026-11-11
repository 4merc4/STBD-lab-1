using EcommerceApp.Infrastructure;
using EcommerceApp.Models;
using Npgsql;

namespace EcommerceApp.Repositories;

public sealed class ProductRepository : RepositoryBase, IProductRepository
{
    private const string CatalogSelect = @"
        SELECT store_product_id, store_id, store_name, currency, product_id, sku, product_name,
               category_name, brand_name, price, stock_qty, in_stock, avg_rating, reviews_count
          FROM v_product_catalog";

    public ProductRepository(IDbSession session) : base(session) { }

    // ---- запис -----------------------------------------------------------
    public Task<long> CreateAsync(long categoryId, long? brandId, string sku, string name,
                                  string? description, string? attributesJson)
        => CallForIdAsync("sp_product_create", categoryId, brandId, sku, name, description, attributesJson);

    public Task SoftDeleteAsync(long productId) => CallAsync("sp_product_soft_delete", productId);

    public Task RestoreAsync(long productId) => CallAsync("sp_product_restore", productId);

    public Task<long> SetStoreOfferAsync(long storeId, long productId, decimal price, int initialStock)
        => CallForIdAsync("sp_store_product_set", storeId, productId, price, initialStock);

    public Task RestockAsync(long storeProductId, int quantity, string reason = "restock")
        => CallAsync("sp_store_product_restock", storeProductId, quantity, reason);

    // ---- читання ---------------------------------------------------------
    public async Task<IReadOnlyList<CatalogItemDto>> GetCatalogAsync(long storeId)
        => await QueryAsync(CatalogSelect + " WHERE store_id = @store ORDER BY product_name",
                            MapCatalog, ("store", storeId));

    // табличнa функція fn_search_products використовує GIN-індекс повнотекстового пошуку
    public async Task<IReadOnlyList<ProductSearchHitDto>> SearchAsync(long storeId, string text)
        => await QueryAsync(
            @"SELECT store_product_id, product_id, sku, product_name, price, stock_qty, rank
                FROM fn_search_products(@store, @q)",
            r => new ProductSearchHitDto(r.Long("store_product_id"), r.Long("product_id"), r.Str("sku"),
                                         r.Str("product_name"), r.Dec("price"), r.Int("stock_qty"), r.Float("rank")),
            ("store", storeId), ("q", text));

    public async Task<IReadOnlyList<DeletedProductDto>> GetDeletedAsync()
        => await QueryAsync(
            "SELECT product_id, sku, product_name, deleted_at, deleted_by_name FROM v_products_deleted ORDER BY deleted_at DESC",
            r => new DeletedProductDto(r.Long("product_id"), r.Str("sku"), r.Str("product_name"),
                                       r.Time("deleted_at"), r.StrN("deleted_by_name")));

    public async Task<IReadOnlyList<LowStockDto>> GetLowStockAsync()
        => await QueryAsync(
            "SELECT store_product_id, store_id, store_name, sku, product_name, stock_qty FROM v_low_stock ORDER BY stock_qty, store_product_id",
            r => new LowStockDto(r.Long("store_product_id"), r.Long("store_id"), r.Str("store_name"),
                                 r.Str("sku"), r.Str("product_name"), r.Int("stock_qty")));

    private static CatalogItemDto MapCatalog(NpgsqlDataReader r) => new(
        r.Long("store_product_id"), r.Long("store_id"), r.Str("store_name"), r.Str("currency"),
        r.Long("product_id"), r.Str("sku"), r.Str("product_name"), r.Str("category_name"), r.StrN("brand_name"),
        r.Dec("price"), r.Int("stock_qty"), r.Bool("in_stock"), r.DecN("avg_rating"), r.Long("reviews_count"));
}
