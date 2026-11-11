using EcommerceApp.Infrastructure;
using EcommerceApp.Models;
using Npgsql;

namespace EcommerceApp.Repositories;

public sealed class UserRepository : RepositoryBase, IUserRepository
{
    private const string UserSelect = @"
        SELECT id, email, first_name, last_name, full_name, phone, roles, created_at, updated_at, updated_by
          FROM v_users_active";

    public UserRepository(IDbSession session) : base(session) { }

    // ---- запис: тільки збережені процедури ----------------------------
    public Task<long> RegisterAsync(string email, string passwordHash, string firstName, string lastName, string? phone)
        => CallForIdAsync("sp_user_register", email, passwordHash, firstName, lastName, phone);

    public Task UpdateAsync(long userId, string firstName, string lastName, string? phone)
        => CallAsync("sp_user_update", userId, firstName, lastName, phone);

    public Task AssignRoleAsync(long userId, string roleName)
        => CallAsync("sp_user_assign_role", userId, roleName);

    public Task SoftDeleteAsync(long userId) => CallAsync("sp_user_soft_delete", userId);

    public Task RestoreAsync(long userId) => CallAsync("sp_user_restore", userId);

    public Task<long> AddAddressAsync(long userId, string? label, string country, string city,
                                      string streetLine, string? postalCode, bool isDefault)
        => CallForIdAsync("sp_address_add", userId, label, country, city, streetLine, postalCode, isDefault);

    // ---- читання: тільки розрізи ---------------------------------------
    public Task<UserDto?> GetByIdAsync(long userId)
        => QuerySingleAsync(UserSelect + " WHERE id = @id", MapUser, ("id", userId));

    public Task<UserDto?> GetByEmailAsync(string email)
        => QuerySingleAsync(UserSelect + " WHERE lower(email) = lower(@email)", MapUser, ("email", email));

    public async Task<IReadOnlyList<UserDto>> GetAllActiveAsync()
        => await QueryAsync(UserSelect + " ORDER BY id", MapUser);

    public async Task<IReadOnlyList<AddressDto>> GetAddressesAsync(long userId)
        => await QueryAsync(
            @"SELECT address_id, user_id, label, country, city, street_line, postal_code, is_default
                FROM v_user_addresses WHERE user_id = @id ORDER BY address_id",
            r => new AddressDto(r.Long("address_id"), r.Long("user_id"), r.Str("label"), r.Str("country"),
                                r.Str("city"), r.Str("street_line"), r.StrN("postal_code"), r.Bool("is_default")),
            ("id", userId));

    private static UserDto MapUser(NpgsqlDataReader r) => new(
        r.Long("id"), r.Str("email"), r.Str("first_name"), r.Str("last_name"), r.Str("full_name"),
        r.StrN("phone"), r.Str("roles"), r.Time("created_at"), r.TimeN("updated_at"), r.LongN("updated_by"));
}
