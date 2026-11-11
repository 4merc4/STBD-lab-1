using EcommerceApp.Models;

namespace EcommerceApp.Repositories;

public interface IUserRepository
{
    Task<long> RegisterAsync(string email, string passwordHash, string firstName, string lastName, string? phone);
    Task UpdateAsync(long userId, string firstName, string lastName, string? phone);
    Task AssignRoleAsync(long userId, string roleName);
    Task SoftDeleteAsync(long userId);
    Task RestoreAsync(long userId);
    Task<long> AddAddressAsync(long userId, string? label, string country, string city,
                               string streetLine, string? postalCode, bool isDefault);

    Task<UserDto?> GetByIdAsync(long userId);
    Task<UserDto?> GetByEmailAsync(string email);
    Task<IReadOnlyList<UserDto>> GetAllActiveAsync();
    Task<IReadOnlyList<AddressDto>> GetAddressesAsync(long userId);
}

public interface IStoreRepository
{
    Task<IReadOnlyList<StoreDto>> GetActiveAsync();
    Task<StoreDto?> GetBySlugAsync(string slug);
    Task<IReadOnlyList<ShippingMethodDto>> GetShippingMethodsAsync(long storeId);
    Task<IReadOnlyList<StoreSalesDto>> GetSalesSummaryAsync();
}

public interface IProductRepository
{
    Task<long> CreateAsync(long categoryId, long? brandId, string sku, string name,
                           string? description, string? attributesJson);
    Task SoftDeleteAsync(long productId);
    Task RestoreAsync(long productId);

    /// <summary>Виставити товар у магазині (створити / оновити ціну / відновити пропозицію).</summary>
    Task<long> SetStoreOfferAsync(long storeId, long productId, decimal price, int initialStock);
    Task RestockAsync(long storeProductId, int quantity, string reason = "restock");

    Task<IReadOnlyList<CatalogItemDto>> GetCatalogAsync(long storeId);
    Task<IReadOnlyList<ProductSearchHitDto>> SearchAsync(long storeId, string text);
    Task<IReadOnlyList<DeletedProductDto>> GetDeletedAsync();
    Task<IReadOnlyList<LowStockDto>> GetLowStockAsync();
}

public interface ICartRepository
{
    /// <returns>Ідентифікатор кошика (створюється автоматично).</returns>
    Task<long> AddItemAsync(long userId, long storeProductId, int quantity);
    Task RemoveItemAsync(long cartId, long storeProductId);
    Task ClearAsync(long cartId);
    Task<IReadOnlyList<CartLineDto>> GetLinesAsync(long userId, long storeId);
}

public interface IOrderRepository
{
    Task<long> PlaceAsync(long userId, long storeId, long addressId, long shippingMethodId,
                          string? couponCode, string? note);
    Task<long> PayAsync(long orderId, string method, decimal amount, string? transactionRef);
    Task<long> ShipAsync(long orderId, string carrier, string? trackingNumber);
    Task MarkDeliveredAsync(long orderId);
    Task ChangeStatusAsync(long orderId, string newStatus);

    Task<OrderSummaryDto?> GetSummaryAsync(long orderId);
    Task<IReadOnlyList<OrderSummaryDto>> GetByUserAsync(long userId);
    Task<IReadOnlyList<OrderItemDto>> GetItemsAsync(long orderId);
    Task<IReadOnlyList<OrderHistoryDto>> GetHistoryAsync(long orderId);
}

public interface IReviewRepository
{
    Task<long> AddAsync(long userId, long productId, int rating, string? title, string? body);
    Task SoftDeleteAsync(long reviewId);
    Task<IReadOnlyList<ReviewDto>> GetForProductAsync(long productId);
}
