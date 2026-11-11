namespace EcommerceApp.Models;

// DTO відповідають колонкам розрізів (views) із sql/04_views.sql.

public sealed record UserDto(
    long Id, string Email, string FirstName, string LastName, string FullName,
    string? Phone, string Roles, DateTime CreatedAt, DateTime? UpdatedAt, long? UpdatedBy);

public sealed record AddressDto(
    long AddressId, long UserId, string Label, string Country, string City,
    string StreetLine, string? PostalCode, bool IsDefault);

public sealed record StoreDto(
    long Id, string Name, string Slug, string Currency, bool IsActive,
    string OwnerName, DateTime? UpdatedAt, long? UpdatedBy);

public sealed record ShippingMethodDto(
    long ShippingMethodId, long StoreId, string Name, decimal BaseCost, int EstimatedDays);

public sealed record StoreSalesDto(
    long StoreId, string StoreName, long OrdersCount, decimal Revenue, decimal AvgOrderValue);

public sealed record CatalogItemDto(
    long StoreProductId, long StoreId, string StoreName, string Currency,
    long ProductId, string Sku, string ProductName, string CategoryName, string? BrandName,
    decimal Price, int StockQty, bool InStock, decimal? AvgRating, long ReviewsCount);

public sealed record ProductSearchHitDto(
    long StoreProductId, long ProductId, string Sku, string ProductName,
    decimal Price, int StockQty, float Rank);

public sealed record DeletedProductDto(
    long ProductId, string Sku, string ProductName, DateTime DeletedAt, string? DeletedByName);

public sealed record LowStockDto(
    long StoreProductId, long StoreId, string StoreName, string Sku, string ProductName, int StockQty);

public sealed record CartLineDto(
    long CartId, long StoreProductId, string ProductName, decimal UnitPrice,
    int Quantity, decimal LineTotal, int StockQty, decimal CartTotal);

public sealed record OrderSummaryDto(
    long OrderId, string OrderNumber, long UserId, string CustomerName,
    long StoreId, string StoreName, string Status,
    decimal Subtotal, decimal DiscountAmount, decimal ShippingCost, decimal TotalAmount,
    string? CouponCode, long ItemsCount, string? PaymentStatus,
    DateTime CreatedAt, DateTime? UpdatedAt, long? UpdatedBy);

public sealed record OrderItemDto(
    long OrderId, long ItemId, string Sku, string ProductName,
    decimal UnitPrice, int Quantity, decimal LineTotal);

public sealed record OrderHistoryDto(
    long OrderId, string? OldStatus, string NewStatus, DateTime ChangedAt, string? ChangedByName);

public sealed record ReviewDto(
    long ReviewId, long ProductId, string ProductName, long UserId, string ReviewerName,
    int Rating, string? Title, string? Body, DateTime CreatedAt);
