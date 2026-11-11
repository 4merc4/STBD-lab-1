using EcommerceApp.Infrastructure;
using EcommerceApp.Models;

namespace EcommerceApp.Repositories;

public sealed class CartRepository : RepositoryBase, ICartRepository
{
    public CartRepository(IDbSession session) : base(session) { }

    public Task<long> AddItemAsync(long userId, long storeProductId, int quantity)
        => CallForIdAsync("sp_cart_add_item", userId, storeProductId, quantity);

    public Task RemoveItemAsync(long cartId, long storeProductId)
        => CallAsync("sp_cart_remove_item", cartId, storeProductId);

    public Task ClearAsync(long cartId) => CallAsync("sp_cart_clear", cartId);

    public async Task<IReadOnlyList<CartLineDto>> GetLinesAsync(long userId, long storeId)
        => await QueryAsync(
            @"SELECT cart_id, store_product_id, product_name, unit_price, quantity, line_total, stock_qty, cart_total
                FROM v_cart_details
               WHERE user_id = @user AND store_id = @store
               ORDER BY store_product_id",
            r => new CartLineDto(r.Long("cart_id"), r.Long("store_product_id"), r.Str("product_name"),
                                 r.Dec("unit_price"), r.Int("quantity"), r.Dec("line_total"),
                                 r.Int("stock_qty"), r.Dec("cart_total")),
            ("user", userId), ("store", storeId));
}
