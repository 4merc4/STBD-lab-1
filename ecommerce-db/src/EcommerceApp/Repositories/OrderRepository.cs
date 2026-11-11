using EcommerceApp.Infrastructure;
using EcommerceApp.Models;
using Npgsql;

namespace EcommerceApp.Repositories;

public sealed class OrderRepository : RepositoryBase, IOrderRepository
{
    private const string OrderSelect = @"
        SELECT order_id, order_number, user_id, customer_name, store_id, store_name, status,
               subtotal, discount_amount, shipping_cost, total_amount, coupon_code, items_count,
               payment_status, created_at, updated_at, updated_by
          FROM v_order_summary";

    public OrderRepository(IDbSession session) : base(session) { }

    // ---- запис -----------------------------------------------------------
    public Task<long> PlaceAsync(long userId, long storeId, long addressId, long shippingMethodId,
                                 string? couponCode, string? note)
        => CallForIdAsync("sp_order_place", userId, storeId, addressId, shippingMethodId, couponCode, note);

    public Task<long> PayAsync(long orderId, string method, decimal amount, string? transactionRef)
        => CallForIdAsync("sp_payment_register", orderId, method, amount, transactionRef);

    public Task<long> ShipAsync(long orderId, string carrier, string? trackingNumber)
        => CallForIdAsync("sp_shipment_create", orderId, carrier, trackingNumber);

    public Task MarkDeliveredAsync(long orderId) => CallAsync("sp_shipment_mark_delivered", orderId);

    public Task ChangeStatusAsync(long orderId, string newStatus)
        => CallAsync("sp_order_change_status", orderId, newStatus);

    // ---- читання ---------------------------------------------------------
    public Task<OrderSummaryDto?> GetSummaryAsync(long orderId)
        => QuerySingleAsync(OrderSelect + " WHERE order_id = @id", MapOrder, ("id", orderId));

    public async Task<IReadOnlyList<OrderSummaryDto>> GetByUserAsync(long userId)
        => await QueryAsync(OrderSelect + " WHERE user_id = @id ORDER BY created_at DESC, order_id DESC",
                            MapOrder, ("id", userId));

    public async Task<IReadOnlyList<OrderItemDto>> GetItemsAsync(long orderId)
        => await QueryAsync(
            @"SELECT order_id, item_id, sku, product_name, unit_price, quantity, line_total
                FROM v_order_items_detail WHERE order_id = @id ORDER BY item_id",
            r => new OrderItemDto(r.Long("order_id"), r.Long("item_id"), r.Str("sku"), r.Str("product_name"),
                                  r.Dec("unit_price"), r.Int("quantity"), r.Dec("line_total")),
            ("id", orderId));

    public async Task<IReadOnlyList<OrderHistoryDto>> GetHistoryAsync(long orderId)
        => await QueryAsync(
            @"SELECT order_id, old_status, new_status, changed_at, changed_by_name
                FROM v_order_history WHERE order_id = @id ORDER BY changed_at",
            r => new OrderHistoryDto(r.Long("order_id"), r.StrN("old_status"), r.Str("new_status"),
                                     r.Time("changed_at"), r.StrN("changed_by_name")),
            ("id", orderId));

    private static OrderSummaryDto MapOrder(NpgsqlDataReader r) => new(
        r.Long("order_id"), r.Str("order_number"), r.Long("user_id"), r.Str("customer_name"),
        r.Long("store_id"), r.Str("store_name"), r.Str("status"),
        r.Dec("subtotal"), r.Dec("discount_amount"), r.Dec("shipping_cost"), r.Dec("total_amount"),
        r.StrN("coupon_code"), r.Long("items_count"), r.StrN("payment_status"),
        r.Time("created_at"), r.TimeN("updated_at"), r.LongN("updated_by"));
}
